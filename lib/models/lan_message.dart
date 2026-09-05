// 局域网喊话的消息体。严格遵守「两个字段」的约束：name 和 msg。
// 其余所有体验（着色、气泡对齐、排序等）都在客户端根据 name 推导，不在此模型加字段。
class LanMessage {
  final String name;
  final String msg;

  const LanMessage({required this.name, required this.msg});

  Map<String, dynamic> toJson() => {'name': name, 'msg': msg};

  factory LanMessage.fromJson(Map<String, dynamic> json) => LanMessage(
        name: (json['name'] as Object?)?.toString() ?? '',
        msg: (json['msg'] as Object?)?.toString() ?? '',
      );
}
