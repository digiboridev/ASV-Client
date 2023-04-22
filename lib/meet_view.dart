import 'dart:async';
import 'package:asv_client/core/constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:asv_client/domain/controllers/room_client.dart';
import 'package:asv_client/utils/first_where_or_null.dart';

class MeetConnection {
  MeetConnection({
    required this.clientId,
    required this.roomClient,
    MediaStream? txStream,
  }) {
    renderer = RTCVideoRenderer();
    renderer.initialize();
    _eventSubscription = roomClient.eventStream.listen(eventHandler);

    // Start transmitting if tx stream provided
    if (txStream != null) initTx(txStream);
  }

  final String clientId;
  final RoomClient roomClient;

  late final RTCVideoRenderer renderer;
  late final StreamSubscription<RoomEvent> _eventSubscription;

  RTCPeerConnection? _txPc;
  RTCPeerConnection? _rxPc;

  /// Set or remove stream to transmit.
  ///
  /// If stream is null, the current stream will be removed.
  ///
  /// If stream is not null, the current stream will be replaced
  set setTxStream(MediaStream? stream) {
    _txPc?.close();
    _txPc = null;
    if (stream != null) initTx(stream);
  }

  initTx(MediaStream stream) async {
    _txPc?.close();
    RTCPeerConnection txPc = await createPeerConnection(peerConfig);
    _txPc = txPc;

    txPc.onConnectionState = (state) {
      debugPrint('onConnectionState tx: $state');
      // Recover connection if lost
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (_txPc != null) initTx(stream);
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (_txPc != null) initTx(stream);
      }
    };

    List<RTCIceCandidate> candidates = [];

    txPc.onIceCandidate = (candidate) {
      debugPrint('onIceCandidate tx: $candidate');
      // Future.delayed(const Duration(seconds: 1)).then((value) {
      roomClient.sendCandidate(clientId, PcType.tx, candidate);
      candidates.add(candidate);
      // });
    };

    stream.getTracks().forEach((track) {
      txPc.addTrack(track, stream);
    });

    final offer = await txPc.createOffer();
    txPc.setLocalDescription(offer);
    roomClient.sendOffer(clientId, offer);

    // Retryable function to wait for answer
    try {
      // Wait for answer
      RoomEvent answer = await roomClient.eventStream.firstWhere((event) {
        return event is MeetConnectionAnswer && event.clientId == clientId;
      }).timeout(const Duration(seconds: 5));

      debugPrint('Received answer');
      // Check if peer is not null because it could be disposed while waiting for answer
      if (_txPc != null) _txPc!.setRemoteDescription((answer as MeetConnectionAnswer).answer);

      // Send stored candidates
      candidates.forEach((candidate) => roomClient.sendCandidate(clientId, PcType.tx, candidate));
    } on TimeoutException {
      debugPrint('Timeout waiting for answer');
      // Check if peer is not null because it could be disposed while waiting for answer
      // Than retry connection
      if (_txPc != null) initTx(stream);
    }
  }

  initRx(RTCSessionDescription offer) async {
    _rxPc?.close();
    RTCPeerConnection rxPc = await createPeerConnection(peerConfig);
    _rxPc = rxPc;

    rxPc.onIceCandidate = (candidate) {
      debugPrint('onIceCandidate rx: $candidate');
      roomClient.sendCandidate(clientId, PcType.rx, candidate);
    };

    rxPc.onConnectionState = (state) {
      debugPrint('onConnectionState rx: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _rxPc?.close();
        renderer.srcObject = null;
      }
    };

    rxPc.onTrack = (track) {
      debugPrint('onTrack rx: $track');
      renderer.srcObject = track.streams.first;
    };

    rxPc.setRemoteDescription(offer);
    final answer = await rxPc.createAnswer();
    rxPc.setLocalDescription(answer);
    roomClient.sendAnswer(clientId, answer);
  }

  eventHandler(RoomEvent event) {
    if (event is MeetConnectionOffer && event.clientId == clientId) {
      initRx(event.offer);
    }

    if (event is MeetConnectionCandidate) {
      if (event.clientId == clientId) {
        debugPrint('Received candidate');
        // Pay attention to the pcType here
        // RX candidate is for TX pc and vice versa
        if (event.pcType == PcType.tx) {
          if (_rxPc != null) {
            _rxPc!.addCandidate(event.candidate);
          }
        } else {
          if (_txPc != null) {
            _txPc!.addCandidate(event.candidate);
          }
        }
      }
    }
  }

  dispose() {
    _rxPc?.close();
    _rxPc = null;
    _txPc?.close();
    _txPc = null;
    renderer.srcObject = null;
    renderer.dispose();
    _eventSubscription.cancel();
  }
}

class MeetView extends StatefulWidget {
  const MeetView({super.key, required this.roomClient});

  final RoomClient roomClient;

  @override
  State<MeetView> createState() => _MeetViewState();
}

class _MeetViewState extends State<MeetView> {
  late final StreamSubscription<RoomEvent> eventSubscription;
  MediaStream? localStream;
  final localRenderer = RTCVideoRenderer();
  List<MeetConnection> connections = [];

  @override
  void initState() {
    super.initState();
    localRenderer.initialize();

    eventSubscription = widget.roomClient.eventStream.listen((event) async {
      if (event is ClientJoin) {
        MeetConnection? connection = connections.firstWhereOrNull((connection) => connection.clientId == event.clientId);
        if (connection != null) return;
        connections.add(MeetConnection(
          clientId: event.clientId,
          roomClient: widget.roomClient,
          txStream: localStream,
        ));
      }

      if (event is ClientSignal) {
        MeetConnection? connection = connections.firstWhereOrNull((connection) => connection.clientId == event.clientId);
        if (connection != null) return;
        connections.add(MeetConnection(
          clientId: event.clientId,
          roomClient: widget.roomClient,
          txStream: localStream,
        ));
      }

      if (event is ClientLeave) {
        MeetConnection? connection = connections.firstWhereOrNull((connection) => connection.clientId == event.clientId);
        connection?.dispose();
        connections.remove(connection);
      }

      setState(() {});
    });
  }

  Future streamCamera() async {
    stopStream();
    final stream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': true});
    localStream = stream;
    localRenderer.srcObject = stream;
    for (var connection in connections) {
      connection.setTxStream = stream;
    }
  }

  Future streamDisplay() async {
    stopStream();
    final stream = await navigator.mediaDevices.getDisplayMedia({'audio': true, 'video': true});
    localStream = stream;
    localRenderer.srcObject = stream;
    for (var connection in connections) {
      connection.setTxStream = stream;
    }
  }

  stopStream() async {
    for (var connection in connections) {
      connection.setTxStream = null;
    }
    if (kIsWeb) {
      localStream?.getTracks().forEach((track) => track.stop());
    }
    localRenderer.srcObject = null;
    localStream?.dispose();
    localStream = null;
  }

  @override
  void deactivate() {
    super.deactivate();
    stopStream();
    eventSubscription.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: streamCamera,
          child: const Text('Start camera'),
        ),
        TextButton(
          onPressed: streamDisplay,
          child: const Text('Start display'),
        ),
        TextButton(
          onPressed: stopStream,
          child: const Text('Stop stream'),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Container(
                  color: Colors.amber,
                  width: 100,
                  height: 100,
                  child: RTCVideoView(
                    localRenderer,
                    mirror: true,
                  ),
                ),
                ...connections
                    .map(
                      (connection) => Container(
                        color: Colors.blue,
                        width: 100,
                        height: 100,
                        child: RTCVideoView(connection.renderer),
                      ),
                    )
                    .toList()
              ],
            ),
          ),
        ),
      ],
    );
  }
}
