// Copyright 2026 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

import 'dart:async';
import 'dart:convert';

import 'package:devtools_app/src/screens/logging/logging_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart';

void main() {
  group('LogData serialization', () {
    test('toJson and fromJson round trip with full data', () {
      final original = LogData(
        'stdout',
        '{"message":"hello world"}',
        123456789,
        summary: 'hello world summary',
        level: Level.WARNING.value,
        isError: true,
        isolateRef: IsolateRef(
          id: 'isolates/1',
          number: '1',
          name: 'main-isolate',
          isSystemIsolate: false,
        ),
        zone: (name: 'RootZone', identityHashCode: 999),
      );

      final json = original.toJson();
      final decoded = LogData.fromJson(json);

      expect(decoded.kind, 'stdout');
      expect(decoded.details, '{"message":"hello world"}');
      expect(decoded.timestamp, 123456789);
      expect(decoded.summary, 'hello world summary');
      expect(decoded.level, Level.WARNING.value);
      expect(decoded.levelName, 'WARNING');
      expect(decoded.isError, isTrue);
      expect(decoded.needsComputing, isFalse);
      expect(decoded.isolateRef?.id, 'isolates/1');
      expect(decoded.isolateRef?.name, 'main-isolate');
      expect(decoded.isolateRef?.number, '1');
      expect(decoded.isolateRef?.isSystemIsolate, isFalse);
      expect(decoded.zone?.name, 'RootZone');
      expect(decoded.zone?.identityHashCode, 999);
      expect(decoded.prettyPrinted(), contains('"message": "hello world"'));
      expect(decoded.encodedDetails, '{"message":"hello world"}');
    });

    test('toJson and fromJson round trip with minimal data', () {
      final original = LogData('custom.event', null, 500);

      final json = original.toJson();
      final decoded = LogData.fromJson(json);

      expect(decoded.kind, 'custom.event');
      expect(decoded.details, isNull);
      expect(decoded.timestamp, 500);
      expect(decoded.summary, isNull);
      expect(decoded.level, Level.INFO.value);
      expect(decoded.levelName, 'INFO');
      expect(decoded.isError, isFalse);
      expect(decoded.needsComputing, isFalse);
      expect(decoded.isolateRef, isNull);
      expect(decoded.zone, isNull);
      expect(decoded.prettyPrinted(), isNull);
      expect(decoded.encodedDetails, '');
    });

    test('isError defaults level to SEVERE if level omitted in json', () {
      final json = <String, Object?>{'kind': 'stderr', 'isError': true};

      final decoded = LogData.fromJson(json);

      expect(decoded.isError, isTrue);
      expect(decoded.level, Level.SEVERE.value);
      expect(decoded.levelName, 'SEVERE');
    });

    test(
      'falls back to summary when details needs computing at export time',
      () {
        final completer = Completer<String>();
        final log = LogData(
          'pending.log',
          null,
          100,
          summary: 'summary fallback text',
          detailsComputer: () => completer.future,
        );

        expect(log.needsComputing, isTrue);
        final json = log.toJson();
        expect(json['details'], 'summary fallback text');

        final decoded = LogData.fromJson(json);
        expect(decoded.details, 'summary fallback text');
        expect(decoded.needsComputing, isFalse);
      },
    );

    test('exports resolved details after detailsComputer completes', () async {
      final completer = Completer<String>();
      final log = LogData(
        'async.log',
        null,
        100,
        summary: 'initial summary',
        detailsComputer: () => completer.future,
      );

      completer.complete('resolved details content');
      await log.compute();

      expect(log.needsComputing, isFalse);
      final json = log.toJson();
      expect(json['details'], 'resolved details content');

      final decoded = LogData.fromJson(json);
      expect(decoded.details, 'resolved details content');
    });

    test('round trips zone with partial fields', () {
      final logNameOnly = LogData(
        'event',
        'details',
        0,
        zone: (name: 'CustomZone', identityHashCode: null),
      );
      final decodedNameOnly = LogData.fromJson(logNameOnly.toJson());
      expect(decodedNameOnly.zone?.name, 'CustomZone');
      expect(decodedNameOnly.zone?.identityHashCode, isNull);

      final logHashOnly = LogData(
        'event',
        'details',
        0,
        zone: (name: null, identityHashCode: 12345),
      );
      final decodedHashOnly = LogData.fromJson(logHashOnly.toJson());
      expect(decodedHashOnly.zone?.name, isNull);
      expect(decodedHashOnly.zone?.identityHashCode, 12345);
    });

    test('matchesSearchToken on deserialized LogData', () {
      final log = LogData.fromJson({
        'kind': 'flutter.error',
        'level': Level.SHOUT.value,
        'summary': 'Widget build failed',
        'details': 'Exception in RenderFlex',
        'isolateRef': {'id': 'iso1', 'name': 'ui-thread'},
        'zone': {'name': 'error-zone'},
      });

      expect(
        log.matchesSearchToken(RegExp('flutter.error', caseSensitive: false)),
        isTrue,
      );
      expect(
        log.matchesSearchToken(RegExp('SHOUT', caseSensitive: false)),
        isTrue,
      );
      expect(
        log.matchesSearchToken(RegExp('Widget build', caseSensitive: false)),
        isTrue,
      );
      expect(
        log.matchesSearchToken(RegExp('RenderFlex', caseSensitive: false)),
        isTrue,
      );
      expect(
        log.matchesSearchToken(RegExp('ui-thread', caseSensitive: false)),
        isTrue,
      );
      expect(
        log.matchesSearchToken(RegExp('error-zone', caseSensitive: false)),
        isTrue,
      );
      expect(
        log.matchesSearchToken(RegExp('nonexistent', caseSensitive: false)),
        isFalse,
      );
    });

    test('toJson encodes to valid JSON string and can be decoded', () {
      final original = LogData(
        'json.test',
        'details value',
        42,
        summary: 'summary value',
        isolateRef: IsolateRef(id: 'iso1', name: 'main'),
        zone: (name: 'ZoneA', identityHashCode: 10),
      );

      final jsonString = jsonEncode(original.toJson());
      final parsedJson = (jsonDecode(jsonString) as Map)
          .cast<String, Object?>();
      final restored = LogData.fromJson(parsedJson);

      expect(restored.kind, original.kind);
      expect(restored.details, original.details);
      expect(restored.timestamp, original.timestamp);
      expect(restored.summary, original.summary);
      expect(restored.level, original.level);
      expect(restored.isolateRef?.name, original.isolateRef?.name);
      expect(restored.zone?.name, original.zone?.name);
      expect(restored.zone?.identityHashCode, original.zone?.identityHashCode);
    });
  });
}
