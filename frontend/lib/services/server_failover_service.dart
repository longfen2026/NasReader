// lib/services/server_failover_service.dart
/// 已废弃：Tailnet 回退由 [NetworkClient] 在单个连接请求失败时处理。
///
/// 保留空类型仅避免旧版外部导入立即失效；应用内不再调用此服务。
@Deprecated('Tailnet fallback is handled by NetworkClient.')
class ServerFailoverService {
  ServerFailoverService._();
}
