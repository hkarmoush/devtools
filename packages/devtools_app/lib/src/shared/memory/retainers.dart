// Copyright 2024 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:typed_data';

import '../primitives/utils.dart';

/// Returns true if the given object can retain other objects from garbage collection.
typedef IsWeak = bool Function(int index);

/// List of references for the given object.
typedef References = List<int> Function(int index);

/// Shallow size of the given object.
typedef ShallowSize = int Function(int index);

typedef ShortestRetainersResult = ({
  /// Retainer for each object in the graph.
  ///
  /// When a value at index i is 0, it means the object at index i
  /// has no retainers.
  /// Null is not used for no-retainer to save memory footprint.
  List<int> retainers,

  /// Retained size for each object in the graph.
  ///
  /// If an object is unreachable, its retained size is 0.
  List<int>? retainedSizes,
});

/// Index of the sentinel object.
const _sentinelIndex = 0;

/// Finds shortest retainers for each object in the graph.
///
/// Index 0 is reserved for sentinel object.
/// The sentinel object should not have size and references.
///
/// Releases the UI thread periodically, so a big graph does not freeze the UI.
Future<ShortestRetainersResult> findShortestRetainers({
  required int graphSize,
  required int rootIndex,
  required IsWeak isWeak,
  required References refs,
  required ShallowSize shallowSize,
  bool calculateSizes = true,
}) async {
  assert(refs(_sentinelIndex).isEmpty);
  assert(
    shallowSize(_sentinelIndex) <= 0,
    'Sentinel should have size 0 or -1 (not defined), but size is ${shallowSize(_sentinelIndex)}.',
  );
  assert(
    rootIndex != _sentinelIndex,
    'Root index should not be $_sentinelIndex, it is reserved for no-retainer.',
  );

  final retainers = Uint32List(graphSize);
  Uint32List? retainedSizes;
  if (calculateSizes) {
    retainedSizes = Uint32List(graphSize);
    retainedSizes[rootIndex] = shallowSize(rootIndex);
  }

  // Objects in the order they are reached from the root, excluding the root.
  //
  // Every object is reached after its retainer. That makes the reversed order
  // suitable for accumulating retained sizes from leaves to the root.
  // Weak objects and objects without references are included, because they
  // are retained too, even though they do not retain other objects.
  final reached = calculateSizes ? Uint32List(graphSize) : null;
  var reachedCount = 0;

  final uiReleaser = UiReleaser();

  // Array of all objects where the best distance from root is n.
  // n starts with 0 and increases by 1 on each step of the algorithm.
  // The objects are ends of the graph cut.
  // See description of cut:
  // https://en.wikipedia.org/wiki/Cut_(graph_theory)
  // On each step the algorithm moves the cut one step further from the root.
  var cut = [rootIndex];

  while (cut.isNotEmpty) {
    final nextCut = <int>[];
    for (final index in cut) {
      for (final ref in refs(index)) {
        if (ref == _sentinelIndex || ref == rootIndex || retainers[ref] != 0) {
          continue;
        }
        retainers[ref] = index;
        reached?[reachedCount++] = ref;
        if (!isWeak(ref)) nextCut.add(ref);

        if (uiReleaser.step()) await uiReleaser.releaseUi();
      }
    }
    cut = nextCut;
  }

  if (retainedSizes != null && reached != null) {
    _calculateRetainedSizes(
      retainedSizes: retainedSizes,
      retainers: retainers,
      reached: reached,
      reachedCount: reachedCount,
      shallowSize: shallowSize,
    );
  }

  return (retainers: retainers, retainedSizes: retainedSizes);
}

/// Sets retained size of each reached object to the sum of shallow sizes
/// of the object and of all objects it retains.
///
/// Time is O(number of objects). Walking the retainer chain of each object
/// instead would be O(number of objects * length of the chain).
void _calculateRetainedSizes({
  required Uint32List retainedSizes,
  required Uint32List retainers,
  required Uint32List reached,
  required int reachedCount,
  required ShallowSize shallowSize,
}) {
  for (var i = 0; i < reachedCount; i++) {
    final index = reached[i];
    retainedSizes[index] = shallowSize(index);
  }

  // Each object comes after its retainer in [reached], so by the time an
  // object is added to its retainer, the object already includes everything it
  // retains.
  for (var i = reachedCount - 1; i >= 0; i--) {
    final index = reached[i];
    retainedSizes[retainers[index]] += retainedSizes[index];
  }
}
