// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:typed_data';

import 'package:devtools_app/src/shared/memory/retainers.dart';
import 'package:devtools_app/src/shared/memory/simple_items.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_infra/test_data/memory/heap/heap_data.dart';

void main() {
  group('findShortestRetainers on a small graph', () {
    // 0 is the sentinel, 1 is the root.
    //
    // 1 -> 2 -> 3 -> 4
    // 1 -> 5 (weak, so it does not retain the object 6 it references)
    // 3 -> 2 (cycle)
    // 4 -> 1 (reference to the root)
    // 7 is unreachable.
    const refsByIndex = <int, List<int>>{
      0: [],
      1: [2, 5],
      2: [3],
      3: [4, 2],
      4: [1],
      5: [6],
      6: [],
      7: [2],
    };
    const sizes = <int, int>{
      0: 0,
      1: 10,
      2: 20,
      3: 30,
      4: 40,
      5: 50,
      6: 60,
      7: 70,
    };

    late ShortestRetainersResult result;

    setUp(() async {
      result = await findShortestRetainers(
        graphSize: refsByIndex.length,
        rootIndex: heapRootIndex,
        isWeak: (i) => i == 5 || refsByIndex[i]!.isEmpty,
        refs: (i) => refsByIndex[i]!,
        shallowSize: (i) => sizes[i]!,
      );
    });

    test('finds retainers.', () {
      expect(result.retainers, [0, 0, 1, 2, 3, 1, 0, 0]);
    });

    test('includes weak objects and leaves in retained sizes.', () {
      // Object 6 is not reached through the weak object 5, so it is not
      // retained and has no size.
      expect(result.retainedSizes, [0, 150, 90, 70, 40, 50, 0, 0]);
    });

    test('does not give the root a retainer.', () {
      expect(result.retainers[heapRootIndex], 0);
    });
  });

  group('findShortestRetainers on a long chain', () {
    test('does not overflow the stack.', () async {
      const length = 200000;
      final result = await findShortestRetainers(
        graphSize: length + 2,
        rootIndex: heapRootIndex,
        isWeak: (i) => i == length + 1,
        refs: (i) => i == 0 || i == length + 1 ? Uint32List(0) : [i + 1],
        shallowSize: (i) => i == 0 ? 0 : 1,
      );

      expect(result.retainedSizes![heapRootIndex], length + 1);
    });
  });

  for (final t in goldenHeapTests) {
    test('matches the reference implementation on ${t.fileName}.', () async {
      final graph = await t.loadHeap();

      bool isWeak(int i) => graph.objects[i].references.isEmpty;
      List<int> refs(int i) => graph.objects[i].references;
      int shallowSize(int i) => graph.objects[i].shallowSize;

      final result = await findShortestRetainers(
        graphSize: graph.objects.length,
        rootIndex: heapRootIndex,
        isWeak: isWeak,
        refs: refs,
        shallowSize: shallowSize,
      );
      final expected = _referenceFindShortestRetainers(
        graphSize: graph.objects.length,
        rootIndex: heapRootIndex,
        isWeak: isWeak,
        refs: refs,
        shallowSize: shallowSize,
      );

      expect(result.retainers, expected.retainers);
      expect(result.retainedSizes, expected.retainedSizes);
    });
  }
}

/// The implementation from before retained sizes were calculated in
/// one pass, kept to verify the results are the same.
///
/// It walks the whole retainer chain for each object, so it is slow.
({Uint32List retainers, Uint32List retainedSizes})
_referenceFindShortestRetainers({
  required int graphSize,
  required int rootIndex,
  required bool Function(int) isWeak,
  required List<int> Function(int) refs,
  required int Function(int) shallowSize,
}) {
  final retainers = Uint32List(graphSize);
  final retainedSizes = Uint32List(graphSize);
  retainedSizes[rootIndex] = shallowSize(rootIndex);

  var cut = [rootIndex];
  while (cut.isNotEmpty) {
    final nextCut = <int>[];
    for (final index in cut) {
      for (final ref in refs(index)) {
        if (ref == 0 || retainers[ref] != 0) continue;
        retainers[ref] = index;
        retainedSizes[ref] = shallowSize(ref);

        var current = ref;
        final addedSize = shallowSize(ref);
        while (retainers[current] > 0) {
          current = retainers[current];
          retainedSizes[current] += addedSize;
        }
        if (!isWeak(ref)) nextCut.add(ref);
      }
    }
    cut = nextCut;
  }
  return (retainers: retainers, retainedSizes: retainedSizes);
}
