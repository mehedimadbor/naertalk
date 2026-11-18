import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const NearTalk());

class NearTalk extends StatelessWidget {
  const NearTalk({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Near Talk',
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: const Color(0xFF0B1220),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF3B82F6)),
        ),
        home: const Home(),
      );
}

class Msg {
  final String id, from, text;
  final int ts;
  Msg(this.id, this.from, this.text, this.ts);
  Map<String, dynamic> toJson() => {'id': id, 'from': from, 'text': text, 'ts': ts};
  factory Msg.fromJson(Map j) => Msg(j['id'], j['from'], j['text'], j['ts']);
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final nearby = Nearby();
  final strategy = Strategy.P2P_CLUSTER; // Bluetooth + Wi-Fi, no internet
  static const serviceId = 'com.neartalk.app';
  final String me = 'User${1000 + Random().nextInt(9000)}';
  final names = <String, String>{}; // endpointId -> name
  final peers = <String, String>{}; // connected endpointId -> name
  final found = <String, String>{};
  final msgs = <Msg>[];
  final ctl = TextEditingController();
  int tab = 0;
  String status = 'Starting...';

  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> start() async {
    await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ].request();
    try {
      await nearby.startAdvertising(me, strategy,
          onConnectionInitiated: onInit,
          onConnectionResult: onResult,
          onDisconnected: onDisc,
          serviceId: serviceId);
      await nearby.startDiscovery(me, strategy,
          onEndpointFound: (id, name, sid) {
            found[id] = name;
            // only one side requests, to avoid double connections
            if (me.compareTo(name) < 0) {
              nearby.requestConnection(me, id,
                  onConnectionInitiated: onInit,
                  onConnectionResult: onResult,
                  onDisconnected: onDisc);
            }
            setState(() {});
          },
          onEndpointLost: (id) => setState(() => found.remove(id)),
          serviceId: serviceId);
      setState(() => status = 'Searching nearby...');
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
  }

  void onInit(String id, ConnectionInfo info) {
    names[id] = info.endpointName;
    nearby.acceptConnection(id,
        onPayLoadRecieved: (eid, p) {
          if (p.type == PayloadType.BYTES && p.bytes != null) {
            handle(utf8.decode(p.bytes!));
          }
        },
        onPayloadTransferUpdate: (eid, u) {});
  }

  void onResult(String id, Status s) {
    if (s == Status.CONNECTED) {
      peers[id] = names[id] ?? id;
      // share full inbox so both phones see the same conversation
      sendTo(id, {'t': 'sync', 'm': msgs.map((m) => m.toJson()).toList()});
    }
    setState(() => status = peers.isEmpty ? 'Searching nearby...' : 'Connected');
  }

  void onDisc(String id) => setState(() {
        peers.remove(id);
        status = peers.isEmpty ? 'Searching nearby...' : 'Connected';
      });

  void sendTo(String id, Map o) =>
      nearby.sendBytesPayload(id, Uint8List.fromList(utf8.encode(jsonEncode(o))));

  void handle(String s) {
    final o = jsonDecode(s);
    final list = o['t'] == 'sync' ? o['m'] as List : [o['m']];
    for (final j in list) {
      final m = Msg.fromJson(j);
      if (msgs.every((x) => x.id != m.id)) msgs.add(m);
    }
    msgs.sort((a, b) => a.ts.compareTo(b.ts));
    setState(() {});
  }

  void send() {
    final t = ctl.text.trim();
    if (t.isEmpty) return;
    final m = Msg('${me}_${DateTime.now().microsecondsSinceEpoch}', me, t,
        DateTime.now().millisecondsSinceEpoch);
    msgs.add(m);
    for (final id in peers.keys) {
      sendTo(id, {'t': 'msg', 'm': m.toJson()});
    }
    ctl.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connected = peers.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1220),
        title: Text(tab == 0 ? 'Shared Inbox' : 'Nearby'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              label: Text(connected ? 'Connected: ${peers.values.join(", ")}' : status),
              backgroundColor: connected ? const Color(0xFF14532D) : const Color(0xFF131C2E),
            ),
          )
        ],
      ),
      body: tab == 0 ? chat() : nearbyList(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Inbox'),
          NavigationDestination(icon: Icon(Icons.bluetooth_searching), label: 'Nearby'),
        ],
      ),
    );
  }

  Widget chat() => Column(children: [
        Expanded(
          child: msgs.isEmpty
              ? const Center(child: Text('No messages yet'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i], mine = m.from == me;
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(12),
                        constraints: const BoxConstraints(maxWidth: 280),
                        decoration: BoxDecoration(
                          color: mine ? const Color(0xFF1D4ED8) : const Color(0xFF131C2E),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (!mine)
                            Text(m.from, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                          Text(m.text),
                        ]),
                      ),
                    );
                  }),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: ctl,
                  onSubmitted: (_) => send(),
                  decoration: InputDecoration(
                    hintText: 'Message',
                    filled: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                  ),
                ),
              ),
              IconButton.filled(onPressed: send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]);

  Widget nearbyList() => ListView(padding: const EdgeInsets.all(16), children: [
        Text('You are: $me', style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 12),
        for (final e in found.entries)
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(e.value),
            subtitle: Text(peers.containsKey(e.key) ? 'Connected' : 'Found'),
            trailing: peers.containsKey(e.key)
                ? null
                : TextButton(
                    onPressed: () => nearby.requestConnection(me, e.key,
                        onConnectionInitiated: onInit,
                        onConnectionResult: onResult,
                        onDisconnected: onDisc),
                    child: const Text('Connect')),
          ),
        if (found.isEmpty) const Text('No one nearby yet. Open the app on the other phone.'),
      ]);
}
