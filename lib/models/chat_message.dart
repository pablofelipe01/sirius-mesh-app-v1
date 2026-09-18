enum DeliveryStatus {
  sending,    // Enviado, esperando ACK (reloj gris)
  delivered,  // ACK recibido (check verde)
  failed,     // Error de routing (X roja)
  none,       // Mensajes recibidos o broadcast (sin indicador de entrega)
}

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
  DeliveryStatus deliveryStatus;

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
    this.deliveryStatus = DeliveryStatus.none,
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'messageText': messageText,
        'fromNodeId': fromNodeId,
        'fromNodeName': fromNodeName,
        'timestamp': timestamp.toIso8601String(),
        'channel': channel,
        'toNodeId': toNodeId,
        'isDirectMessage': isDirectMessage,
        'isMine': isMine,
        'deliveryStatus': deliveryStatus.name,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String?,
        messageText: json['messageText'] as String,
        fromNodeId: json['fromNodeId'] as int,
        fromNodeName: json['fromNodeName'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        channel: json['channel'] as int,
        toNodeId: json['toNodeId'] as int?,
        isDirectMessage: json['isDirectMessage'] as bool,
        isMine: json['isMine'] as bool,
        deliveryStatus: DeliveryStatus.values.firstWhere(
          (s) => s.name == json['deliveryStatus'],
          orElse: () => DeliveryStatus.none,
        ),
      );
}

class MeshNode {
  final int nodeId;
  final String nodeName;
  final bool isOnline;
  final DateTime? lastSeen;
  final int? batteryLevel; // 0-100, >100 = USB powered
  final double? voltage;

  MeshNode({
    required this.nodeId,
    required this.nodeName,
    this.isOnline = true,
    this.lastSeen,
    this.batteryLevel,
    this.voltage,
  });

  String get displayName => nodeName.isNotEmpty ? nodeName : 'Nodo !${nodeId.toRadixString(16)}';
  String get shortId => '!${nodeId.toRadixString(16)}';

  /// Indica si el nodo está alimentado por USB (batteryLevel > 100)
  bool get isUsbPowered => batteryLevel != null && batteryLevel! > 100;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshNode && nodeId == other.nodeId;

  @override
  int get hashCode => nodeId.hashCode;
}

/// Solicitud de visitante
class VisitorRequest {
  final int requestId;
  final String visitorName;
  final String reason;
  final String area;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  bool isResponded;
  String? responseStatus; // APROBADO, NEGADO, PENDIENTE
  DateTime? exitTime;

  VisitorRequest({
    required this.requestId,
    required this.visitorName,
    required this.reason,
    required this.area,
    required this.fromNodeId,
    required this.fromNodeName,
    required this.timestamp,
    this.isResponded = false,
    this.responseStatus,
    this.exitTime,
  });

  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String get formattedDate {
    final day = timestamp.day.toString().padLeft(2, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    return '$day/$month';
  }

  String? get formattedExitTime {
    if (exitTime == null) return null;
    final hour = exitTime!.hour.toString().padLeft(2, '0');
    final minute = exitTime!.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'visitorName': visitorName,
        'reason': reason,
        'area': area,
        'fromNodeId': fromNodeId,
        'fromNodeName': fromNodeName,
        'timestamp': timestamp.toIso8601String(),
        'isResponded': isResponded,
        'responseStatus': responseStatus,
        'exitTime': exitTime?.toIso8601String(),
      };

  factory VisitorRequest.fromJson(Map<String, dynamic> json) => VisitorRequest(
        requestId: json['requestId'] as int,
        visitorName: json['visitorName'] as String,
        reason: json['reason'] as String,
        area: json['area'] as String,
        fromNodeId: json['fromNodeId'] as int,
        fromNodeName: json['fromNodeName'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        isResponded: json['isResponded'] as bool? ?? false,
        responseStatus: json['responseStatus'] as String?,
        exitTime: json['exitTime'] != null
            ? DateTime.parse(json['exitTime'] as String)
            : null,
      );
}

/// Respuesta a solicitud de visitante
class VisitorResponse {
  final String status; // APROBADO, NEGADO, PENDIENTE
  final String supervisorName;
  final String? comment;
  final int fromNodeId;
  final DateTime timestamp;

  VisitorResponse({
    required this.status,
    required this.supervisorName,
    this.comment,
    required this.fromNodeId,
    required this.timestamp,
  });

  bool get isApproved => status == 'APROBADO';
  bool get isDenied => status == 'NEGADO';
  bool get isPending => status == 'PENDIENTE';
}

class ActiveVisitor {
  final String visitorName;
  final String reason;
  final String area;
  final DateTime entryTime;
  DateTime? exitTime;

  ActiveVisitor({
    required this.visitorName,
    required this.reason,
    required this.area,
    required this.entryTime,
  });

  bool get hasExited => exitTime != null;

  String get formattedEntryTime {
    final hour = entryTime.hour.toString().padLeft(2, '0');
    final minute = entryTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String? get formattedExitTime {
    if (exitTime == null) return null;
    final hour = exitTime!.hour.toString().padLeft(2, '0');
    final minute = exitTime!.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Map<String, dynamic> toJson() => {
        'visitorName': visitorName,
        'reason': reason,
        'area': area,
        'entryTime': entryTime.toIso8601String(),
        'exitTime': exitTime?.toIso8601String(),
      };

  factory ActiveVisitor.fromJson(Map<String, dynamic> json) {
    final v = ActiveVisitor(
      visitorName: json['visitorName'] as String,
      reason: json['reason'] as String,
      area: json['area'] as String,
      entryTime: DateTime.parse(json['entryTime'] as String),
    );
    if (json['exitTime'] != null) {
      v.exitTime = DateTime.parse(json['exitTime'] as String);
    }
    return v;
  }
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
