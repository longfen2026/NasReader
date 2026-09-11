import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/services/server_profile_service.dart';

void main() {
  test('normalizeUrl 去除尾部斜杠，保证同一服务器不产生重复记录', () {
    expect(ServerProfileService.normalizeUrl(' http://nas:6088/// '), 'http://nas:6088');
    expect(ServerProfileService.normalizeUrl('http://nas:6088'), 'http://nas:6088');
    expect(ServerProfileService.normalizeUrl('   '), '');
  });

  test('ServerProfile 序列化往返保持字段', () {
    const profile = ServerProfile(
      url: 'http://nas:6088',
      username: 'alice',
      rememberPassword: false,
    );

    final restored = ServerProfile.fromJson(profile.toJson());
    expect(restored.url, 'http://nas:6088');
    expect(restored.username, 'alice');
    expect(restored.rememberPassword, isFalse);
    expect(restored.toJson(), isNot(contains('backupUrl')));
  });

  test('ServerProfile.fromJson 忽略旧备用地址并默认记住密码', () {
    final profile = ServerProfile.fromJson({
      'url': 'http://nas:6088',
      'backupUrl': 'http://backup:6088',
    });
    expect(profile.username, '');
    expect(profile.rememberPassword, isTrue);
  });

  test('历史记录上限为 3 条', () {
    expect(ServerProfileService.maxProfiles, 3);
  });
}
