// Copyright 2024 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';

import '../primitives/utils.dart';
import 'class_name.dart';
import 'classes.dart';
import 'retainers.dart';
import 'retaining_path.dart';
import 'simple_items.dart';

/// Raw and calculated data of the heap snapshot.
class HeapData {
  HeapData(this.graph, {required this.created}) {
    unawaited(_calculate());
  }

  final HeapSnapshotGraph graph;

  final DateTime created;

  Future<void> get calculate => _calculated.future;
  final _calculated = Completer<void>();

  ClassDataList<SingleClassData>? classes;

  MemoryFootprint? footprint;

  List<int>? retainedSizes;

  /// Object index with the given identityHashCode.
  ///
  /// This field is calculated only for console evaluations.
  late final indexByCode = <int, int>{
    for (var i = 0; i < graph.objects.length; i++)
      if (graph.objects[i].identityHashCode > 0)
        graph.objects[i].identityHashCode: i,
  };

  @visibleForTesting
  bool isReachable(int index) {
    return retainedSizes![index] > 0;
  }

  static final _uiReleaser = UiReleaser();

  /// Calculate the heap data from the given [graph].
  Future<void> _calculate({
    @visibleForTesting bool calculateRetainingPaths = true,
    @visibleForTesting bool calculateRetainedSizes = true,
    @visibleForTesting bool calculateClassData = true,
  }) async {
    if (!calculateClassData) return;

    List<int>? retainers;

    if (calculateRetainingPaths || calculateRetainedSizes) {
      final weakClasses = _WeakClasses(graph);

      final result = await findShortestRetainers(
        graphSize: graph.objects.length,
        rootIndex: heapRootIndex,
        isWeak: weakClasses.isWeak,
        refs: (int index) => graph.objects[index].references,
        shallowSize: (int index) => graph.objects[index].shallowSize,
        calculateSizes: calculateRetainedSizes,
      );

      if (calculateRetainingPaths) retainers = result.retainers;
      if (calculateRetainedSizes) retainedSizes = result.retainedSizes;
    }

    // Complexity of this part is O(n) plus O(r)*O(p), where
    // n is number of objects, r is number of objects that retain other objects,
    // and p is length of retaining path. See [RetainingPaths].
    if (calculateClassData) {
      final nameToClass = <HeapClassName, SingleClassData>{};
      final classNames = [
        for (final c in graph.classes) HeapClassName.fromHeapSnapshotClass(c),
      ];
      final paths = retainers == null
          ? null
          : RetainingPaths(
              graph,
              shortestRetainers: retainers,
              classNames: classNames,
            );
      int dartSize = 0;
      int reachableSize = graph.objects[heapRootIndex].shallowSize;

      for (var i = 0; i < graph.objects.length; i++) {
        if (_uiReleaser.step()) await _uiReleaser.releaseUi();
        final object = graph.objects[i];
        dartSize += object.shallowSize;

        // We do not show unreachable objects, i.e. objects
        // that will be garbage collected soon.
        if (retainers?[i] == 0) {
          continue;
        }

        final className = classNames[object.classId];

        // Ignore sentinels, because their size is not known.
        if (className.isSentinel) {
          assert(object.shallowSize == 0);
          continue;
        }

        reachableSize += object.shallowSize;

        nameToClass
            .putIfAbsent(className, () => SingleClassData(className: className))
            .countInstance(
              graph,
              index: i,
              path: paths?.forObject(i),
              retainedSizes: retainedSizes,
            );
      }

      footprint = MemoryFootprint(dart: dartSize, reachable: reachableSize);
      classes = ClassDataList<SingleClassData>(nameToClass.values.toList());

      // Check that retained size of root is the entire reachable heap.
      assert(
        retainedSizes == null ||
            retainedSizes![heapRootIndex] == footprint!.reachable,
      );
    }

    _calculated.complete();
  }
}

class _WeakClasses {
  _WeakClasses(this.graph) {
    final weakClassesToFind = <String, String>{
      '_WeakProperty': 'dart:core',
      '_WeakReferenceImpl': 'dart:core',
      'FinalizerEntry': 'dart:_internal',
    };

    for (final theClass in graph.classes) {
      if (weakClassesToFind.containsKey(theClass.name) &&
          weakClassesToFind[theClass.name] == theClass.libraryName) {
        _weakClasses.add(theClass.classId);
        weakClassesToFind.remove(theClass.name);
        if (weakClassesToFind.isEmpty) return;
      }
    }
  }

  final HeapSnapshotGraph graph;

  /// Set of class ids that are not holding their references from garbage collection.
  late final _weakClasses = <int>{};

  /// Returns true if the object cannot retain other objects.
  bool isWeak(int objectIndex) {
    final object = graph.objects[objectIndex];
    if (_weakClasses.contains(object.classId)) return true;
    return object.references.isEmpty;
  }
}
