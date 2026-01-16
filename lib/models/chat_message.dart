class ChatMessage {
  final String id;
  final String messageText;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  final int channel;
  final int? toNodeId;
  final bool isDirectMessage;
  final bool isMine;

  ChatMessage({
    String? id,
    required this.messageText,
    required this.fromNodeId,
    required this.fromNodeName,
    required this.timestamp,
    required this.channel,
    this.toNodeId,
    required this.isDirectMessage,
    required this.isMine,
  }) : id = id ?? '${fromNodeId}_${timestamp.millisecondsSinceEpoch}';

  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String get formattedDate {
    final day = timestamp.day.toString().padLeft(2, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    final year = timestamp.year;
    return '$day/$month/$year';
  }

  bool isSameDay(ChatMessage other) {
    return timestamp.year == other.timestamp.year &&
        timestamp.month == other.timestamp.month &&
        timestamp.day == other.timestamp.day;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class MeshNode {
  final int nodeId;
  final String nodeName;
  final bool isOnline;
  final DateTime? lastSeen;

  MeshNode({
    required this.nodeId,
    required this.nodeName,
    this.isOnline = true,
    this.lastSeen,
  });

  String get displayName => nodeName.isNotEmpty ? nodeName : 'Nodo !${nodeId.toRadixString(16)}';
  String get shortId => '!${nodeId.toRadixString(16)}';
}

class ChatDestination {
  final String displayName;
  final int? channel;
  final int? nodeId;
  final bool isChannel;

  const ChatDestination({
    required this.displayName,
    this.channel,
    this.nodeId,
    required this.isChannel,
  });

  static const ChatDestination primaryChannel = ChatDestination(
    displayName: 'Canal 0: Primary',
    channel: 0,
    isChannel: true,
  );

  static const ChatDestination supervisorsChannel = ChatDestination(
    displayName: 'Canal 1: Supervisores',
    channel: 1,
    isChannel: true,
  );

  static ChatDestination directMessage(MeshNode node) {
    return ChatDestination(
      displayName: 'DM: ${node.displayName}',
      nodeId: node.nodeId,
      isChannel: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatDestination &&
          runtimeType == other.runtimeType &&
          channel == other.channel &&
          nodeId == other.nodeId;

  @override
  int get hashCode => Object.hash(channel, nodeId);
}
