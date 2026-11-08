import 'package:astation_mobile/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> workspace() => {
  'bridgeVersion': 1,
  'context': 'native-context',
  'revision': 1,
  'environment': 'development',
  'account': {'id': 'account-a', 'name': 'Owner'},
  'access': 'control',
  'deviceName': 'Phone',
  'deviceId': 'member-a',
  'loginAvailable': true,
  'hosts': [
    {'id': 'host-a', 'name': 'Genie', 'platform': 'Linux', 'online': true},
  ],
  'agents': [
    {
      'target': target(),
      'name': 'Mobile',
      'provider': 'Codex',
      'activity': 'unknown',
      'lifecycle': 'running',
      'updatedAt': '2026-11-03T12:00:00Z',
      'preview': '',
      'connected': true,
      'canControl': true,
    },
  ],
  'approvals': [],
  'profiles': [],
  'conversations': [],
  'rules': [],
};
Map<String, Object?> target() => {
  'account': 'account-a',
  'host': 'host-a',
  'trustGeneration': 1,
  'session': 'session-a',
  'processGeneration': 'process-a',
};

void main() {
  test('device enrollment requires an explicit native capability', () {
    expect(
      WorkspaceSnapshot.fromJson(workspace()).enrollmentAvailable,
      isFalse,
    );
    expect(
      WorkspaceSnapshot.fromJson(workspace()..['enrollmentAvailable'] = true)
          .enrollmentAvailable,
      isTrue,
    );
    expect(
      () => WorkspaceSnapshot.fromJson(
        workspace()..['enrollmentAvailable'] = 'true',
      ),
      throwsFormatException,
    );
  });

  test('native presentation cannot enable design preview', () {
    final json = workspace()..['preview'] = true;
    final parsed = WorkspaceSnapshot.fromJson(json);
    expect(parsed.preview, isFalse);
    expect(parsed.agents.single.activity, AgentActivity.unknown);
    expect(parsed.agents.single.lifecycle, AgentLifecycle.running);
  });
  test('all target generations participate in equality', () {
    final original = AgentTarget.fromJson(target());
    for (final entry in <String, Object?>{
      'account': 'other',
      'host': 'other',
      'trustGeneration': 2,
      'session': 'other',
      'processGeneration': 'other',
    }.entries) {
      final changed = target()..[entry.key] = entry.value;
      expect(AgentTarget.fromJson(changed), isNot(original));
    }
    expect(AgentTarget.fromJson(target()), original);
  });
  test('cross-account, unlisted host and duplicate targets are rejected', () {
    for (final field in ['account', 'host']) {
      final json = workspace();
      final agent = (json['agents'] as List).single as Map<String, Object?>;
      (agent['target'] as Map)[field] = 'other';
      expect(() => WorkspaceSnapshot.fromJson(json), throwsFormatException);
    }
    final duplicate = workspace();
    (duplicate['agents'] as List).add((duplicate['agents'] as List).single);
    expect(() => WorkspaceSnapshot.fromJson(duplicate), throwsFormatException);
  });
  test(
    'approval and conversation from an old process cannot attach to a new one',
    () {
      for (final list in ['approvals', 'conversations', 'rules']) {
        final json = workspace();
        final stale = target()..['processGeneration'] = 'retired-process';
        json[list] = [
          switch (list) {
            'approvals' => {
              'id': 'approval-a',
              'target': stale,
              'summary': 'Run tests',
              'command': 'npm test',
              'expiresAt': '2026-11-03T12:05:00Z',
              'state': 'pending',
              'rules': [],
            },
            'rules' => {
              'target': stale,
              'rule': {'id': 'rule-a', 'label': 'npm test', 'scope': 'session'},
            },
            _ => {
              'target': stale,
              'messages': [],
              'loading': false,
              'canLoadEarlier': false,
            },
          },
        ];
        expect(() => WorkspaceSnapshot.fromJson(json), throwsFormatException);
      }
    },
  );
  test('signed-out state cannot carry live data or authority', () {
    final json = workspace()..['account'] = null;
    expect(() => WorkspaceSnapshot.fromJson(json), throwsFormatException);
    json['hosts'] = [];
    json['agents'] = [];
    expect(() => WorkspaceSnapshot.fromJson(json), throwsFormatException);
    json['access'] = 'notEnrolled';
    expect(WorkspaceSnapshot.fromJson(json).account, isNull);
  });
  test('version, enum and safe integer limits are enforced', () {
    for (final entry in <String, Object?>{
      'bridgeVersion': 2,
      'revision': 9007199254740992,
      'access': 'manager-admin',
      'environment': 'other',
    }.entries) {
      final json = workspace()..[entry.key] = entry.value;
      expect(() => WorkspaceSnapshot.fromJson(json), throwsFormatException);
    }
  });
}
