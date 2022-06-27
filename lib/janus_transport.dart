part of janus_client;

abstract class JanusTransport {
  String? url;
  int? sessionId;

  JanusTransport({this.url});
  /// this is called internally whenever [JanusSession] or [JanusPlugin] is disposed for cleaning up of active connections either polling or websocket connection.
  void dispose();
}
///
/// This transport class is provided to [JanusClient] instances in transport property in order to <br>
/// inform the plugin that we need to use Rest as a transport mechanism for communicating with Janus Server.<br>
/// therefore for events sent by Janus server is received with the help of polling.
class RestJanusTransport extends JanusTransport {
  RestJanusTransport({String? url}) : super(url: url);

  /*
  * method for posting data to janus by using http client
  * */
  Future<dynamic> post(body, {int? handleId}) async {
    var suffixUrl = '';
    if (sessionId != null && handleId == null) {
      suffixUrl = suffixUrl + "/$sessionId";
    } else if (sessionId != null && handleId != null) {
      suffixUrl = suffixUrl + "/$sessionId/$handleId";
    }
    try {
      var response = (await http.post(Uri.parse(url! + suffixUrl), body: stringify(body))).body;
      return parse(response);
    } on JsonCyclicError {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    } catch (e) {
      return null;
    }
  }

  /*
  * private method for get data to janus by using http client
  * */
  Future<dynamic> get({handleId}) async {
    var suffixUrl = '';
    if (sessionId != null && handleId == null) {
      suffixUrl = suffixUrl + "/$sessionId";
    } else if (sessionId != null && handleId != null) {
      suffixUrl = suffixUrl + "/$sessionId/$handleId";
    }
    return parse((await http.get(Uri.parse(url! + suffixUrl))).body);
  }

  @override
  void dispose() {}
}
///
/// This transport class is provided to [JanusClient] instances in transport property in order to <br>
/// inform the plugin that we need to use WebSockets as a transport mechanism for communicating with Janus Server.<br>
class WebSocketJanusTransport extends JanusTransport {
  WebSocketJanusTransport({String? url, this.pingInterval}) : super(url: url);
  WebSocketChannel? channel;
  Duration? pingInterval;
  WebSocketSink? sink;
  late Stream stream;
  bool isConnected = false;

  void dispose() {
    if (channel != null && sink != null) {
      sink?.close();
      isConnected = false;
    }
  }
  /// this method is used to send json payload to Janus Server for communicating the intent.
  Future<dynamic> send(Map<String, dynamic> data, {int? handleId}) async {
    if (data['transaction'] != null) {
      data['session_id'] = sessionId;
      if (handleId != null) {
        data['handle_id'] = handleId;
      }
      sink!.add(stringify(data));
      return parse(await stream.firstWhere((element) => (parse(element)['transaction'] == data['transaction']), orElse: () => {}));
    } else {
      throw "transaction key missing in body";
    }
  }
  /// this method is internally called by plugin to establish connection with provided websocket uri.
  void connect() {
    try {
      isConnected = true;
      channel = WebSocketChannel.connect(Uri.parse(url!), protocols: ['janus-protocol']);
    } catch (e) {
      print(e.toString());
      print('something went wrong');
      isConnected = false;
      dispose();
    }
    sink = channel!.sink;
    stream = channel!.stream.asBroadcastStream();
  }
}

class MqttJanusTransport extends JanusTransport {
  MqttJanusTransport({
    required String url,
    required this.publishTopic,
    required this.subscribeTopic,
    this.clientIdentifier,
    String? username,
    String? password,
  })  : assert(publishTopic.isNotEmpty, 'requestTopic is empty'),
        assert(subscribeTopic.isNotEmpty, 'responseTopic is empty'),
        username = Uri.parse(url).userInfo.isEmpty ? username : Uri.parse(url).userInfo.split(':').firstOrNull,
        password = !Uri.parse(url).userInfo.contains(':') ? password : Uri.parse(url).userInfo.split(':').lastOrNull,
        super(url: url);

  final String publishTopic, subscribeTopic;

  final String? clientIdentifier, username, password;

  bool get isConnected => _client.connectionStatus?.state == MqttConnectionState.connected;

  late StreamSubscription _subs;
  late final StreamController<Map<String, dynamic>> sink = () {
    final controller = StreamController<Map<String, dynamic>>();
    _subs = (controller.stream.where((event) => isConnected)).listen((event) {
      final data = JsonEncoder().convert(event);
      final payload = MqttClientPayloadBuilder().addString(data).payload!;
      _client.publishMessage(publishTopic, MqttQos.exactlyOnce, payload);
    });
    return controller;
  }();

  Stream get stream => _client.updates!
      .expand((element) => element)
      .where((event) => event.topic == subscribeTopic)
      .map((event) => event.payload)
      .cast<MqttPublishMessage>()
      .map((event) => event.payload.message)
      .map(utf8.decode);

  late final MqttClient _client = () {
    final uri = Uri.parse(this.url!);
    final url = uri.replace(port: 0, userInfo: '').toString();
    final client = (kIsWeb
        ? MqttBrowserClient(url, clientIdentifier ?? getUuid().v4())
        : MqttServerClient(url, clientIdentifier ?? getUuid().v4()))
      ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
      ..port = uri.port > 0 ? uri.port : null
      ..autoReconnect = true
      ..onConnected = (() => print('Mqtt Server Connected'))
      ..onDisconnected = () => print('Mqtt Server Disconected');
    return client;
  }();

  Future<void> connect() async {
    try {
      final status = await _client.connect(username, password);
      if (status?.state != MqttConnectionState.connected) {
        throw Exception("The state is not connected: ${status?.state.name}:${status?.returnCode?.name}");
      }
      _client.subscribe(subscribeTopic, MqttQos.exactlyOnce);
    } catch (e) {
      print(e.toString());
      print('something went wrong');
      dispose();
      rethrow;
    }
  }

  Future<dynamic> send(Map<String, dynamic> data, {int? handleId}) async {
    final String? transaction = data['transaction'];
    if (transaction?.isEmpty ?? true) {
      throw "transaction key missing in body";
    }

    data['session_id'] = sessionId;

    if (handleId != null) {
      data['handle_id'] = handleId;
    }

    sink.add(data);

    final result = await stream.map(parse).firstWhere((event) => event['transaction'] == transaction, orElse: () {});
    return result;
  }

  void dispose() async {
    await _subs.cancel();
    await sink.close();
    _client.disconnect();
  }
}
