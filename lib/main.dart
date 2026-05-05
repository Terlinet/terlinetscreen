import 'dart:async';
import 'dart:math' as math;
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

void main() {
  runApp(const TerlineTScreenRecord());
}

class TerlineTScreenRecord extends StatelessWidget {
  const TerlineTScreenRecord({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TerlineT Screen Record',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RecorderHomePage(),
    );
  }
}

class Bubble {
  Offset position;
  double radius;
  double speed;
  Color color;
  bool isPopped = false;

  Bubble({required this.position, required this.radius, required this.speed, required this.color});

  void update() {
    position = Offset(position.dx, position.dy - speed);
  }
}

class RecorderHomePage extends StatefulWidget {
  const RecorderHomePage({super.key});

  @override
  State<RecorderHomePage> createState() => _RecorderHomePageState();
}

class _RecorderHomePageState extends State<RecorderHomePage> {
  // Estados de Gravação
  html.MediaStream? _stream;
  html.MediaRecorder? _mediaRecorder;
  final List<html.Blob> _chunks = [];
  bool _isRecording = false;
  Timer? _timer;
  int _secondsElapsed = 0;

  // Estados de Destaque
  Color _selectedColor = Colors.red;
  Offset? _mousePos;
  bool _showLaser = true;
  final List<Offset> _trail = [];
  Timer? _trailTimer;

  // Estado de Edição/Preview
  html.Blob? _finalVideoBlob;
  String? _videoUrl;
  String _selectedFormat = 'webm';

  // Estados de Webcam
  html.MediaStream? _cameraStream;
  bool _showCamera = false;
  bool _removeBackground = false;
  final html.VideoElement _cameraVideoElement = html.VideoElement();
  final html.CanvasElement _cameraCanvas = html.CanvasElement(width: 640, height: 480);
  double _cameraX = 30.0;
  double _cameraY = 300.0;

  // Estado do Vídeo de Fundo
  late VideoPlayerController _videoController;

  // Estados do Jogo de Bolhas
  final List<Bubble> _bubbles = [];
  Timer? _bubbleTimer;
  Timer? _gameLoopTimer;
  Offset? _indexFingerPos;
  dynamic _hands;
  dynamic _selfieSegmentation;
  int _bubblesPopped = 0;

  @override
  void initState() {
    super.initState();

    _videoController = VideoPlayerController.asset('assets/videos/voice.mp4')
      ..initialize().then((_) {
        _videoController.setLooping(true);
        _videoController.setVolume(0);
        _videoController.play();
        setState(() {});
      });

    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(
      'webcam-view',
      (int viewId) => _cameraVideoElement,
    );

    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(
      'webcam-canvas-view',
      (int viewId) => _cameraCanvas,
    );

    _trailTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_trail.isNotEmpty) {
        setState(() {
          _trail.removeAt(0);
        });
      }
    });

    _startGame();
    _initMediaPipe();
  }

  void _initMediaPipe() {
    try {
      final handsClass = js_util.getProperty(html.window, 'Hands');
      final selfieClass = js_util.getProperty(html.window, 'SelfieSegmentation');
      if (handsClass == null || selfieClass == null) return;

      // Inicializa Detecção de Mãos
      _hands = js_util.callConstructor(handsClass, [
        js_util.jsify({
          'locateFile': (file) => 'https://cdn.jsdelivr.net/npm/@mediapipe/hands/$file',
        })
      ]);

      js_util.callMethod(_hands, 'setOptions', [
        js_util.jsify({
          'maxNumHands': 1,
          'modelComplexity': 1,
          'minDetectionConfidence': 0.5,
          'minTrackingConfidence': 0.5
        })
      ]);

      js_util.callMethod(_hands, 'onResults', [
        (results) {
          final multiHandLandmarks = js_util.getProperty(results, 'multiHandLandmarks');
          if (multiHandLandmarks != null && js_util.getProperty(multiHandLandmarks, 'length') > 0) {
            final landmarks = js_util.getProperty(multiHandLandmarks, 0);
            final indexFingerTip = js_util.getProperty(landmarks, 8);
            final double x = js_util.getProperty(indexFingerTip, 'x');
            final double y = js_util.getProperty(indexFingerTip, 'y');
            setState(() {
              final size = MediaQuery.of(context).size;
              _indexFingerPos = Offset((1 - x) * size.width, y * size.height);
              _checkCollisions();
            });
          } else {
            setState(() => _indexFingerPos = null);
          }
        }
      ]);

      // Inicializa Remoção de Fundo (Selfie Segmentation)
      _selfieSegmentation = js_util.callConstructor(selfieClass, [
        js_util.jsify({
          'locateFile': (file) => 'https://cdn.jsdelivr.net/npm/@mediapipe/selfie_segmentation/$file',
        })
      ]);

      js_util.callMethod(_selfieSegmentation, 'setOptions', [
        js_util.jsify({'modelSelection': 1})
      ]);

      js_util.callMethod(_selfieSegmentation, 'onResults', [
        (results) {
          if (!_removeBackground) return;
          final ctx = _cameraCanvas.context2D;
          ctx.save();
          ctx.clearRect(0, 0, _cameraCanvas.width!, _cameraCanvas.height!);
          ctx.drawImage(js_util.getProperty(results, 'segmentationMask'), 0, 0);
          ctx.globalCompositeOperation = 'source-in';
          ctx.drawImage(js_util.getProperty(results, 'image'), 0, 0);
          ctx.restore();
        }
      ]);
    } catch (e) {
      debugPrint('Erro ao inicializar MediaPipe: $e');
    }
  }

  void _startGame() {
    _bubbleTimer = Timer.periodic(const Duration(milliseconds: 800), (timer) {
      if (mounted) {
        setState(() {
          final random = math.Random();
          final size = MediaQuery.of(context).size;
          _bubbles.add(Bubble(
            position: Offset(random.nextDouble() * size.width, size.height + 50),
            radius: 20 + random.nextDouble() * 30,
            speed: 2 + random.nextDouble() * 4,
            color: Colors.blueAccent.withOpacity(0.6),
          ));
        });
      }
    });

    _gameLoopTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (mounted) {
        setState(() {
          for (var bubble in _bubbles) {
            bubble.update();
          }
          _bubbles.removeWhere((b) => b.position.dy < -100 || b.isPopped);
        });
      }
    });
  }

  void _checkCollisions() {
    if (_indexFingerPos == null) return;
    for (var bubble in _bubbles) {
      if (!bubble.isPopped) {
        double dist = (bubble.position - _indexFingerPos!).distance;
        if (dist < bubble.radius) {
          bubble.isPopped = true;
          _bubblesPopped++;
          // Feedback visual opcional aqui
        }
      }
    }
  }

  Future<void> _startRecording() async {
    try {
      final displayPromise = js_util.callMethod(
        html.window.navigator.mediaDevices!,
        'getDisplayMedia',
        [js_util.jsify({'video': true, 'audio': true})],
      );
      final html.MediaStream displayStream = await js_util.promiseToFuture(displayPromise);

      html.MediaStream? audioStream;
      try {
        audioStream = await html.window.navigator.mediaDevices!.getUserMedia({'audio': true});
      } catch (e) {
        debugPrint('Microfone não acessível: $e');
      }

      final dynamic audioContext = js_util.callConstructor(
        js_util.getProperty(html.window, 'AudioContext') ?? js_util.getProperty(html.window, 'webkitAudioContext'),
        [],
      );
      final dynamic destination = js_util.callMethod(audioContext, 'createMediaStreamDestination', []);

      bool hasAudio = false;

      if (displayStream.getAudioTracks().isNotEmpty) {
        final dynamic source = js_util.callMethod(audioContext, 'createMediaStreamSource', [displayStream]);
        js_util.callMethod(source, 'connect', [destination]);
        hasAudio = true;
      }

      if (audioStream != null && audioStream.getAudioTracks().isNotEmpty) {
        final dynamic source = js_util.callMethod(audioContext, 'createMediaStreamSource', [audioStream]);
        js_util.callMethod(source, 'connect', [destination]);
        hasAudio = true;
      }

      final combinedStream = html.MediaStream();
      displayStream.getVideoTracks().forEach(combinedStream.addTrack);
      
      if (hasAudio) {
        final html.MediaStream mixedAudioStream = js_util.getProperty(destination, 'stream');
        mixedAudioStream.getAudioTracks().forEach(combinedStream.addTrack);
      }

      _stream = combinedStream;
      _chunks.clear();

      String mimeType = 'video/webm;codecs=vp8,opus';
      if (_selectedFormat == 'mp4') {
        if (html.MediaRecorder.isTypeSupported('video/mp4;codecs=h264,aac')) {
          mimeType = 'video/mp4;codecs=h264,aac';
        } else if (html.MediaRecorder.isTypeSupported('video/mp4')) {
          mimeType = 'video/mp4';
        }
      }

      _mediaRecorder = html.MediaRecorder(_stream!, {'mimeType': mimeType});

      _mediaRecorder!.addEventListener('dataavailable', (event) {
        final html.Blob blob = js_util.getProperty(event, 'data');
        if (blob.size > 0) _chunks.add(blob);
      });

      _mediaRecorder!.addEventListener('stop', (event) {
        setState(() {
          _finalVideoBlob = html.Blob(_chunks, _selectedFormat == 'mp4' ? 'video/mp4' : 'video/webm');
          _videoUrl = html.Url.createObjectUrlFromBlob(_finalVideoBlob!);
        });
        js_util.callMethod(audioContext, 'close', []);
      });

      _mediaRecorder!.start();
      setState(() {
        _isRecording = true;
        _secondsElapsed = 0;
        _finalVideoBlob = null;
      });
      _startTimer();
    } catch (e) {
      debugPrint('Erro ao iniciar gravação: $e');
    }
  }

  void _stopRecording() {
    _mediaRecorder?.stop();
    _stream?.getTracks().forEach((track) => track.stop());
    _timer?.cancel();
    setState(() {
      _isRecording = false;
    });
  }

  void _enterPiP() {
    try {
      js_util.callMethod(_cameraVideoElement, 'requestPictureInPicture', []);
    } catch (e) {
      debugPrint('Erro ao entrar em modo PiP: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Seu navegador não suporta modo flutuante para câmera.')),
        );
      }
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _secondsElapsed++);
    });
  }

  String _formatTime(int seconds) {
    final minutes = (seconds / 60).floor().toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  void _takeScreenshot() {
    if (_stream == null) return;
    
    final videoTracks = _stream!.getVideoTracks();
    if (videoTracks.isEmpty) return;

    final videoElement = html.VideoElement()
      ..srcObject = _stream
      ..muted = true
      ..autoplay = true;

    videoElement.onLoadedMetadata.listen((_) {
      Timer(const Duration(milliseconds: 100), () {
        final canvas = html.CanvasElement(
          width: videoElement.videoWidth,
          height: videoElement.videoHeight,
        );
        canvas.context2D.drawImage(videoElement, 0, 0);
        
        final dataUrl = canvas.toDataUrl('image/png');
        final anchor = html.AnchorElement(href: dataUrl)
          ..setAttribute("download", "TerlineT_Captura_${DateTime.now().millisecondsSinceEpoch}.png")
          ..click();
        
        videoElement.srcObject = null;
      });
    });
  }

  Future<void> _toggleCamera() async {
    if (_showCamera) {
      _cameraStream?.getTracks().forEach((track) => track.stop());
      _cameraVideoElement.srcObject = null;
      setState(() => _showCamera = false);
    } else {
      try {
        final devices = await html.window.navigator.mediaDevices!.enumerateDevices();
        final hasVideoInput = devices.any((device) => device.kind == 'videoinput');

        if (!hasVideoInput) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Nenhuma câmera detectada no seu dispositivo.'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return;
        }

        _cameraStream = await html.window.navigator.mediaDevices!.getUserMedia({'video': true});
        _cameraVideoElement
          ..srcObject = _cameraStream
          ..autoplay = true
          ..muted = true
          ..style.objectFit = 'cover'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.borderRadius = '50%';
        
        // Envia o vídeo para o MediaPipe
        final camera = js_util.callConstructor(js_util.getProperty(html.window, 'Camera'), [
          _cameraVideoElement,
          js_util.jsify({
            'onFrame': () async {
              final image = js_util.jsify({'image': _cameraVideoElement});
              await js_util.promiseToFuture(js_util.callMethod(_hands, 'send', [image]));
              if (_removeBackground) {
                await js_util.promiseToFuture(js_util.callMethod(_selfieSegmentation, 'send', [image]));
              }
            },
            'width': 640,
            'height': 480
          })
        ]);
        js_util.callMethod(camera, 'start', []);

        setState(() => _showCamera = true);
      } catch (e) {
        debugPrint('Erro ao abrir câmera: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Erro ao acessar a câmera.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_finalVideoBlob != null) {
      return VideoEditorPage(
        videoUrl: _videoUrl!,
        onClose: () => setState(() {
          _finalVideoBlob = null;
          _videoUrl = null;
        }),
      );
    }

    return Scaffold(
      body: MouseRegion(
        onHover: (event) {
          setState(() {
            _mousePos = event.localPosition;
            if (_isRecording) {
              _trail.add(event.localPosition);
              if (_trail.length > 20) _trail.removeAt(0);
            }
          });
        },
        child: Stack(
          children: [
            SizedBox.expand(
              child: _videoController.value.isInitialized
                  ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _videoController.value.size.width,
                        height: _videoController.value.size.height,
                        child: VideoPlayer(_videoController),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Colors.black, Colors.deepPurple.shade900],
                        ),
                      ),
                    ),
            ),
            
            Container(color: Colors.black.withOpacity(0.3)),

            // JOGO DE BOLHAS
            CustomPaint(
              size: Size.infinite,
              painter: BubblePainter(_bubbles),
            ),

            // MIRA DO DEDO
            if (_indexFingerPos != null)
              Positioned(
                left: _indexFingerPos!.dx - 20,
                top: _indexFingerPos!.dy - 20,
                child: const Text(
                  '☝️',
                  style: TextStyle(fontSize: 40),
                ),
              ),

            // CONTADOR DE BUBBLESCOINS
            Positioned(
              right: 20,
              bottom: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.blueAccent.withOpacity(0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🫧', style: TextStyle(fontSize: 20)),
                        const SizedBox(width: 8),
                        Text(
                          '$_bubblesPopped BUBBLESCOINS',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const Text(
                      'PRONTO PARA FUTURA INTEGRAÇÃO',
                      style: TextStyle(color: Colors.blueAccent, fontSize: 8, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),

            if (_isRecording && _showLaser)
              CustomPaint(
                size: Size.infinite,
                painter: LaserPointerPainter(_mousePos, _trail, _selectedColor),
              ),

            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!_isRecording) ...[
                    const Text(
                      'INTERATIVIDADE COM INTELIGÊNCIA ARTIFICIAL',
                      style: TextStyle(color: Colors.blueAccent, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        'Após clicar no botão para gravar, ative sua CÂMERA (ícone de rosto) para começar.\n'
                        'Nossa IA rastreia a ponta do seu DEDO INDICADOR em tempo real.\n'
                        'Mantenha sua mão entre 30cm e 1m de distância para melhor detecção.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13, height: 1.5),
                      ),
                    ),
                    const SizedBox(height: 30),
                    const Icon(Icons.security_rounded, size: 40, color: Colors.greenAccent),
                    const SizedBox(height: 10),
                    const Icon(Icons.videocam_rounded, size: 80, color: Colors.white),
                    const Text(
                      'TerlineT Screen Record',
                      style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 15),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.greenAccent.withOpacity(0.5)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.verified_user_rounded, color: Colors.greenAccent, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'PRIVACIDADE TOTAL: GRAVAÇÃO 100% LOCAL',
                            style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      'Seus vídeos e áudios nunca saem do seu computador.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const SizedBox(height: 30),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Formato: ', style: TextStyle(color: Colors.white70)),
                        const SizedBox(width: 10),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'webm', label: Text('WEBM'), icon: Icon(Icons.video_file)),
                            ButtonSegment(value: 'mp4', label: Text('MP4'), icon: Icon(Icons.movie)),
                          ],
                          selected: {_selectedFormat},
                          onSelectionChanged: (Set<String> newSelection) {
                            setState(() {
                              _selectedFormat = newSelection.first;
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                  if (_isRecording)
                    Column(
                      children: [
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.circle, color: Colors.red, size: 12),
                            SizedBox(width: 8),
                            Text('GRAVAÇÃO PRIVADA EM CURSO', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _formatTime(_secondsElapsed),
                          style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  const SizedBox(height: 40),
                  _buildRecordButton(),
                ],
              ),
            ),
          
          if (_isRecording)
            Positioned(
              left: 20,
              top: 100,
              child: _buildToolbar(),
            ),
          
            if (_showCamera)
            Positioned(
              left: _cameraX,
              top: _cameraY,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    _cameraX += details.delta.dx;
                    _cameraY += details.delta.dy;
                  });
                },
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10)],
                  ),
                  child: ClipOval(
                    child: HtmlElementView(viewType: _removeBackground ? 'webcam-canvas-view' : 'webcam-view'),
                  ),
                ),
              ),
            ),

          _buildSideLinks(),
        ],
      ),
    ),
    );
  }

  Widget _buildSideLinks() {
    final links = [
      {
        'url': 'https://terlinet.github.io/terlinet/',
        'name': 'TerlineT',
        'emoji': '👽',
        'desc': 'Inovação Pura 100% IA'
      },
      {
        'url': 'https://terlinet.github.io/bee/',
        'name': 'Bee',
        'emoji': '🐝',
        'desc': 'Agente IA Inteligente'
      },
      {
        'url': 'https://terlinet.github.io/vision/',
        'name': 'Vision',
        'emoji': '😎',
        'desc': 'Visão Computacional IA'
      },
      {
        'url': 'https://tertulianonews.github.io/bubbleschain/#/bubbles',
        'name': 'BubblesChain',
        'emoji': '🫧',
        'desc': 'Blockchain e IA Nativa'
      },
    ];

    return Positioned(
      top: 10,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
            ),
            child: const Text(
              'SISTEMAS 100% IA - TECNOLOGIAS INOVADORAS',
              style: TextStyle(
                color: Colors.blueAccent,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: links.map((link) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Tooltip(
                      message: '${link['name']}: ${link['desc']}',
                      child: InkWell(
                        onTap: () => html.window.open(link['url'] as String, '_blank'),
                        borderRadius: BorderRadius.circular(30),
                        child: Column(
                          children: [
                            Container(
                              width: 45,
                              height: 45,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  center: const Alignment(-0.3, -0.3),
                                  radius: 0.8,
                                  colors: [
                                    Colors.white.withOpacity(0.3),
                                    Colors.blueAccent.withOpacity(0.1),
                                    Colors.blueAccent.withOpacity(0.4),
                                  ],
                                  stops: const [0.0, 0.5, 1.0],
                                ),
                                border: Border.all(color: Colors.white30, width: 1),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 5,
                                    offset: Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Text(
                                link['emoji'] as String,
                                style: const TextStyle(fontSize: 22),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              link['name'] as String,
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordButton() {
    return InkWell(
      onTap: _isRecording ? _stopRecording : _startRecording,
      borderRadius: BorderRadius.circular(50),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 80, height: 80,
        decoration: BoxDecoration(
          color: _isRecording ? Colors.red : Colors.white,
          shape: BoxShape.circle,
        ),
        child: Icon(
          _isRecording ? Icons.stop : Icons.fiber_manual_record,
          size: 40, color: _isRecording ? Colors.white : Colors.red,
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          _colorButton(Colors.red),
          _colorButton(Colors.yellow),
          _colorButton(Colors.greenAccent),
          _colorButton(Colors.blueAccent),
          _colorButton(Colors.white),
          const SizedBox(height: 8),
          IconButton(
            icon: Icon(Icons.ads_click, color: _showLaser ? Colors.greenAccent : Colors.white70),
            onPressed: () => setState(() => _showLaser = !_showLaser),
            tooltip: 'Ponteiro Laser',
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt, color: Colors.white70),
            onPressed: _takeScreenshot,
            tooltip: 'Tirar Foto da Tela',
          ),
          IconButton(
            icon: Icon(Icons.face, color: _showCamera ? Colors.greenAccent : Colors.white70),
            onPressed: _toggleCamera,
            tooltip: 'Ativar Webcam',
          ),
          if (_showCamera)
            IconButton(
              icon: Icon(Icons.blur_on, color: _removeBackground ? Colors.greenAccent : Colors.white70),
              onPressed: () => setState(() => _removeBackground = !_removeBackground),
              tooltip: 'Remover Fundo (IA)',
            ),
          if (_showCamera)
            IconButton(
              icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white70),
              onPressed: _enterPiP,
              tooltip: 'Modo Flutuante (Sempre no Topo)',
            ),
        ],
      ),
    );
  }

  Widget _colorButton(Color color) {
    return GestureDetector(
      onTap: () => setState(() => _selectedColor = color),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        width: 25, height: 25,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: _selectedColor == color ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _trailTimer?.cancel();
    _bubbleTimer?.cancel();
    _gameLoopTimer?.cancel();
    _videoController.dispose();
    _cameraStream?.getTracks().forEach((track) => track.stop());
    super.dispose();
  }
}

class BubblePainter extends CustomPainter {
  final List<Bubble> bubbles;
  BubblePainter(this.bubbles);

  @override
  void paint(Canvas canvas, Size size) {
    for (var bubble in bubbles) {
      // Gradiente Radial para efeito 3D (esfera)
      final paint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.3),
          radius: 0.5,
          colors: [
            Colors.white.withOpacity(0.8),    // Brilho do reflexo
            bubble.color.withOpacity(0.4),    // Cor principal translúcida
            bubble.color.withOpacity(0.7),    // Borda mais escura
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(
          center: bubble.position,
          radius: bubble.radius,
        ));
      
      // Brilho externo (glow)
      final shadowPaint = Paint()
        ..color = bubble.color.withOpacity(0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

      // Desenha o brilho, a bolha e o contorno
      canvas.drawCircle(bubble.position, bubble.radius + 2, shadowPaint);
      canvas.drawCircle(bubble.position, bubble.radius, paint);
      
      final borderPaint = Paint()
        ..color = Colors.white.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      
      canvas.drawCircle(bubble.position, bubble.radius, borderPaint);

      // Pequeno reflexo extra no topo para dar mais realismo
      final highlightPaint = Paint()
        ..color = Colors.white.withOpacity(0.5)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(bubble.position.dx - bubble.radius * 0.4, bubble.position.dy - bubble.radius * 0.4),
        bubble.radius * 0.15, 
        highlightPaint
      );
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}

class LaserPointerPainter extends CustomPainter {
  final Offset? position;
  final List<Offset> trail;
  final Color color;

  LaserPointerPainter(this.position, this.trail, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (position == null) return;

    if (trail.isNotEmpty) {
      final paintTrail = Paint()
        ..color = color.withOpacity(0.3)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 8.0
        ..style = PaintingStyle.stroke;

      final path = Path();
      path.moveTo(trail.first.dx, trail.first.dy);
      for (var point in trail) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paintTrail);
    }

    final paintLaser = Paint()
      ..color = color.withOpacity(0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    
    canvas.drawCircle(position!, 15, paintLaser);

    final paintCenter = Paint()..color = color;
    canvas.drawCircle(position!, 5, paintCenter);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class VideoEditorPage extends StatefulWidget {
  final String videoUrl;
  final VoidCallback onClose;

  const VideoEditorPage({super.key, required this.videoUrl, required this.onClose});

  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  late html.VideoElement _videoElement;
  double _startTrim = 0.0;
  double _endTrim = 1.0;
  double _duration = 0.0;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _videoElement = html.VideoElement()
      ..src = widget.videoUrl
      ..autoplay = false
      ..controls = false
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.borderRadius = '12px';

    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(
      'video-editor-view',
      (int viewId) => _videoElement,
    );

    _videoElement.onLoadedMetadata.listen((_) {
      setState(() {
        _duration = _videoElement.duration.toDouble();
        _endTrim = _duration;
      });
    });

    _videoElement.onTimeUpdate.listen((_) {
      if (_videoElement.currentTime >= _endTrim) {
        _videoElement.currentTime = _startTrim;
      }
      setState(() {});
    });
  }

  void _togglePlay() {
    setState(() {
      if (_videoElement.paused) {
        _videoElement.play();
        _isPlaying = true;
      } else {
        _videoElement.pause();
        _isPlaying = false;
      }
    });
  }

  void _downloadVideo() {
    final extension = widget.videoUrl.contains('video/mp4') || !widget.videoUrl.contains('video/webm') ? 'mp4' : 'webm';
    final anchor = html.AnchorElement(href: widget.videoUrl)
      ..setAttribute("download", "TerlineT_Editado_${DateTime.now().millisecondsSinceEpoch}.$extension")
      ..click();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Editor TerlineT'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onClose),
        actions: [
          TextButton.icon(
            onPressed: _downloadVideo,
            icon: const Icon(Icons.download, color: Colors.greenAccent),
            label: const Text('SALVAR', style: TextStyle(color: Colors.greenAccent)),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(15),
              ),
              child: const HtmlElementView(viewType: 'video-editor-view'),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle, size: 64, color: Colors.white),
                      onPressed: _togglePlay,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text('CORTAR VÍDEO', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                if (_duration > 0)
                  RangeSlider(
                    values: RangeValues(_startTrim, _endTrim),
                    min: 0,
                    max: _duration,
                    activeColor: Colors.deepPurpleAccent,
                    onChanged: (values) {
                      setState(() {
                        _startTrim = values.start;
                        _endTrim = values.end;
                        _videoElement.currentTime = _startTrim;
                      });
                    },
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Início: ${_startTrim.toStringAsFixed(1)}s'),
                    Text('Fim: ${_endTrim.toStringAsFixed(1)}s'),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Dica: Use os controles deslizantes para definir o trecho desejado.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
