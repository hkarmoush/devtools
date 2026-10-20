// Copyright 2024 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';

import '../primitives/utils.dart';
import 'class_name.dart';
import 'simple_items.dart';

// ignore: avoid-dynamic, defined in package:collection
bool Function(List<dynamic>? list1, List<dynamic>? list2) _listEquality =
    const ListEquality().equals;

@visibleForTesting
class DebugRetainingPathUsage {
  /// Path is expected to be constructed for each object.
  // ignore: unused-code, TODO(https://github.com/flutter/devtools/issues/9907) false positive.
  int constructed = 0;

  /// Only unique paths are stored.
  // ignore: unused-code, TODO(https://github.com/flutter/devtools/issues/9907) false positive.
  int stored = 0;

  /// Only displayed paths are stringified.
  // ignore: unused-code, TODO(https://github.com/flutter/devtools/issues/9907) false positive.
  int stringified = 0;
}

/// A retaining path from the root to an object.
///
/// This class is used to represent the shortest retaining path from the root to an object.
///
/// Equal paths are not stored twice in memory.
/// The path does not include the retained object itself.
///
/// The retaining path is represented as a list of classes, ignoring information
/// about concrete instances and fields.
/// To get more detailed information about the retaining path for a specific object,
/// use [`leak_tracker/formattedRetainingPath`](https://github.com/dart-lang/leak_tracker/blob/f5620600a5ce1c44f65ddaa02001e200b096e14c/pkgs/leak_tracker/lib/src/leak_tracking/helpers.dart#L58).
@immutable
class PathFromRoot {
  PathFromRoot._(
    this.path, {
    @visibleForTesting bool debugOmitClassesInRetainingPath = false,
  }) : hashCode = path.isEmpty ? _hashOfEmptyPath : Object.hashAll(path),
       classes = debugOmitClassesInRetainingPath ? const {} : path.toSet() {
    if (kDebugMode) debugUsage.constructed++;
  }

  /// For objects directly referenced from root.
  const PathFromRoot._empty()
    : path = const [],
      classes = const {},
      hashCode = _hashOfEmptyPath;

  factory PathFromRoot.fromPath(
    List<HeapClassName> path, {
    @visibleForTesting debugOmitClassesInRetainingPath = false,
  }) {
    if (path.isEmpty) return empty;
    final existingInstance = instances.lookup(
      PathFromRoot._(
        path,
        debugOmitClassesInRetainingPath: debugOmitClassesInRetainingPath,
      ),
    );
    if (existingInstance != null) return existingInstance;

    final newInstance = PathFromRoot._(
      List.unmodifiable(path),
      debugOmitClassesInRetainingPath: debugOmitClassesInRetainingPath,
    );

    instances.add(newInstance);
    if (kDebugMode) {
      debugUsage.stored++;
      assert(instances.length == debugUsage.stored);
    }
    return newInstance;
  }

  @visibleForTesting
  static void resetSingletons() {
    _instances = null;
    debugUsage = DebugRetainingPathUsage();
  }

  @visibleForTesting
  static Set<PathFromRoot> get instances => _instances ??= <PathFromRoot>{};
  static Set<PathFromRoot>? _instances;

  @visibleForTesting
  static DebugRetainingPathUsage debugUsage = DebugRetainingPathUsage();

  static PathFromRoot empty = const PathFromRoot._empty();

  static const _hashOfEmptyPath = 0;

  /// The retaining path.
  ///
  /// Does not include both the root and the object itself.
  /// Starts from the immediate retainer of the object.
  final List<HeapClassName> path;

  final Set<HeapClassName> classes;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is PathFromRoot && _listEquality(other.path, path);
  }

  @override
  final int hashCode;

  String toShortString({String? delimiter, bool inverted = false}) {
    return _asString(
      data: path.map((e) => e.className).toList(),
      delimiter: _delimiter(
        delimiter: delimiter,
        inverted: inverted,
        isLong: false,
      ),
      inverted: inverted,
    );
  }

  String toLongString({
    String? delimiter,
    bool inverted = false,
    bool hideStandard = false,
  }) {
    final List<String> data;
    bool justAddedEllipsis = false;
    if (hideStandard) {
      data = [];
      for (final item in path.asMap().entries) {
        if (item.key == 0 ||
            item.key == path.length - 1 ||
            !item.value.isCreatedByGoogle) {
          data.add(item.value.fullName);
          justAddedEllipsis = false;
        } else if (!justAddedEllipsis) {
          data.add('...');
          justAddedEllipsis = true;
        }
      }
    } else {
      data = classes.map((e) => e.fullName).toList();
    }

    return _asString(
      data: data,
      delimiter: _delimiter(
        delimiter: delimiter,
        inverted: inverted,
        isLong: true,
      ),
      inverted: inverted,
    );
  }

  static String _delimiter({
    required String? delimiter,
    required bool inverted,
    required bool isLong,
  }) {
    if (delimiter != null) return delimiter;
    if (isLong) {
      return inverted ? '\n→ ' : '\n← ';
    }
    return inverted ? ' → ' : ' ← ';
  }

  static String _asString({
    required List<String> data,
    required String delimiter,
    required bool inverted,
  }) {
    if (kDebugMode) debugUsage.stringified++;
    // Trailing separator is here to show object is referenced by root.
    data = data.joinWith(
      delimiter,
      includeTrailing: true,
      includeLeading: data.isNotEmpty,
    );
    if (inverted) data = data.reversed.toList();
    final result = data.join().trim();
    return result;
  }
}

/// Computes [PathFromRoot]s for the objects of a heap snapshot.
///
/// The path of an object is the path of its retainer with the class of the
/// retainer prepended. Objects that share a retainer, like the elements of a
/// list, therefore share the work, and each retainer is visited once instead
/// of once per retained object. This turns the cost of building all paths from
/// O(objects * path length) into O(retainers * path length).
///
/// Holds one entry per object of the heap, so it should not outlive the
/// calculation it is created for.
class RetainingPaths {
  RetainingPaths(
    HeapSnapshotGraph graph, {
    required this.shortestRetainers,
    required List<HeapClassName> classNames,
  }) : _graph = graph,
       _classNames = classNames,
       _paths = List<PathFromRoot?>.filled(graph.objects.length, null);

  final HeapSnapshotGraph _graph;

  /// Retainer for each object, as returned by `findShortestRetainers`.
  final List<int> shortestRetainers;

  /// Name of each class, by class id.
  ///
  /// Computed once per heap, because creating a [HeapClassName] is too
  /// expensive to do for every step of every path.
  final List<HeapClassName> _classNames;

  /// Path for each object that is already computed, by object index.
  final List<PathFromRoot?> _paths;

  /// Returns the path from the root to the object at [index].
  ///
  /// The object has to be reachable from the root.
  PathFromRoot forObject(int index) {
    // Retainers without a known path, from [index] towards the root.
    // The paths are computed iteratively, because a heap can contain retaining
    // chains that are too long for recursion, for example a long linked list.
    final unknown = <int>[];
    var current = index;
    while (_paths[current] == null) {
      if (shortestRetainers[current] == heapRootIndex) {
        _paths[current] = PathFromRoot.empty;
        break;
      }
      assert(
        shortestRetainers[current] != 0,
        'Object $current is not reachable from the root.',
      );
      unknown.add(current);
      current = shortestRetainers[current];
    }

    for (final object in unknown.reversed) {
      final retainer = shortestRetainers[object];
      _paths[object] = PathFromRoot.fromPath([
        _classNames[_graph.objects[retainer].classId],
        ..._paths[retainer]!.path,
      ]);
    }

    return _paths[index]!;
  }
}
