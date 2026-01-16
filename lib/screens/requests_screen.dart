import 'dart:async';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/meshtastic_service.dart';

class RequestsScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const RequestsScreen({
    super.key,
    required this.meshtasticService,
  });

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  StreamSubscription<VisitorRequest>? _requestSubscription;
  final Map<int, TextEditingController> _commentControllers = {};
  final Set<int> _respondedRequests = {};

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _requestSubscription = _service.requestStream.listen(_onNewRequest);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _requestSubscription?.cancel();
    for (final controller in _commentControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onServiceChange() {
    setState(() {});
  }

  void _onNewRequest(VisitorRequest request) {
    debugPrint('📋 [REQUESTS_SCREEN] Nueva solicitud: ${request.visitorName}');
    setState(() {});
  }

  TextEditingController _getCommentController(int requestId) {
    if (!_commentControllers.containsKey(requestId)) {
      _commentControllers[requestId] = TextEditingController();
    }
    return _commentControllers[requestId]!;
  }

  Future<void> _respond(String status, VisitorRequest request) async {
    final comment = _getCommentController(request.requestId).text.trim();

    final success = await _service.respondToRequest(
      destinationNodeId: request.fromNodeId,
      status: status,
      supervisorName: _service.connectedDeviceName ?? 'Supervisor',
      comment: comment.isNotEmpty ? comment : null,
    );

    if (success) {
      setState(() {
        _respondedRequests.add(request.requestId);
      });
      _service.markRequestResponded(request.requestId, status);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Respuesta "$status" enviada a ${request.fromNodeName}'),
            backgroundColor: status == 'APROBADO' ? Colors.green : Colors.orange,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Error al enviar respuesta'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildRequestCard(VisitorRequest request) {
    final isResponded = _respondedRequests.contains(request.requestId) || request.isResponded;
    final commentController = _getCommentController(request.requestId);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 2,
      color: isResponded ? Colors.grey.shade100 : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header con nombre y hora
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.person, color: Colors.blue, size: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          request.visitorName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${request.formattedDate} ${request.formattedTime}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Motivo y área
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.description, size: 16, color: Colors.grey.shade600),
                      const SizedBox(width: 4),
                      Text(request.reason, style: const TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.location_on, size: 16, color: Colors.grey.shade600),
                      const SizedBox(width: 4),
                      Text(request.area, style: const TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 4),

            // Nodo de origen
            Row(
              children: [
                Icon(Icons.router, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text(
                  'De: ${request.fromNodeName}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),

            if (isResponded) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: request.responseStatus == 'APROBADO'
                      ? Colors.green.shade100
                      : request.responseStatus == 'NEGADO'
                          ? Colors.red.shade100
                          : Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      request.responseStatus == 'APROBADO'
                          ? Icons.check_circle
                          : request.responseStatus == 'NEGADO'
                              ? Icons.cancel
                              : Icons.pending,
                      size: 18,
                      color: request.responseStatus == 'APROBADO'
                          ? Colors.green
                          : request.responseStatus == 'NEGADO'
                              ? Colors.red
                              : Colors.orange,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Respondido: ${request.responseStatus}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: request.responseStatus == 'APROBADO'
                            ? Colors.green.shade700
                            : request.responseStatus == 'NEGADO'
                                ? Colors.red.shade700
                                : Colors.orange.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const Divider(height: 16),

              // Campo de comentario
              TextField(
                controller: commentController,
                decoration: InputDecoration(
                  hintText: 'Comentario opcional...',
                  prefixIcon: const Icon(Icons.comment, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                maxLines: 1,
              ),

              const SizedBox(height: 12),

              // Botones de acción
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _respond('APROBADO', request),
                      icon: const Icon(Icons.check_circle, size: 18),
                      label: const Text('Aprobar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _respond('NEGADO', request),
                      icon: const Icon(Icons.cancel, size: 18),
                      label: const Text('Negar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _respond('PENDIENTE', request),
                      icon: Icon(Icons.pending, size: 18, color: Colors.orange.shade700),
                      label: Text('Pendiente', style: TextStyle(color: Colors.orange.shade700)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.orange.shade700),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final requests = _service.pendingRequests;
    final allRequests = _service.allRequests;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Solicitudes'),
            if (requests.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${requests.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (!_service.isConnected)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Icon(Icons.bluetooth_disabled, color: Colors.red),
            ),
        ],
      ),
      body: allRequests.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No hay solicitudes',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Las solicitudes de visitantes\naparecerán aquí',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: allRequests.length,
              itemBuilder: (context, index) {
                // Mostrar más recientes primero
                final request = allRequests[allRequests.length - 1 - index];
                return _buildRequestCard(request);
              },
            ),
    );
  }
}
