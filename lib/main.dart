// ignore_for_file: curly_braces_in_flow_control_structures
// Reyz Tracer Simulation - simulasi jaringan ala Packet Tracer (versi HP)
import 'dart:convert';
import 'dart:io' show HttpClient;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const kVersion = '1.4.0';
const kBuild = int.fromEnvironment('BUILD', defaultValue: 0); // nomor build (diisi otomatis oleh GitHub Actions)

// Tema: 0 = Biru Dongker (default), 1 = Hitam, 2 = Putih
final themeIdx = ValueNotifier<int>(0), showGrid = ValueNotifier<bool>(true);
Color get kBg => const [Color(0xFF0A1931), Color(0xFF000000), Color(0xFFF2F4F7)][themeIdx.value];
Color get kCard => const [Color(0xFF12284A), Color(0xFF151515), Color(0xFFFFFFFF)][themeIdx.value];
Color get kAcc => const [Color(0xFF00A8FF), Color(0xFFFFFFFF), Color(0xFF000000)][themeIdx.value];
Color get kFg => themeIdx.value == 2 ? Colors.black87 : Colors.white; // warna icon/teks utama
Color get kFg2 => themeIdx.value == 2 ? Colors.black54 : Colors.white70;
const _o = Offset(36, 30); // titik tengah icon device terhadap posisinya

enum T { router, sw, hub, ap, wlc, pc, laptop, server, phone, printer, ipPhone, swSensor, motion, lamp, alarm, iotGw, firewall, cloud, modem, tablet, smartTv, ipCam, tempSensor, doorLock, fan } // perangkat baru ditaruh di belakang supaya file lama tetap kebaca
enum Tool { select, hand, delete, inspect, note, ping, cable }

const tInfo = {
  T.router: ('Router', Icons.router), T.sw: ('Switch', Icons.lan), T.hub: ('Hub', Icons.hub),
  T.ap: ('Access Point', Icons.wifi_tethering), T.wlc: ('WLC', Icons.settings_input_antenna),
  T.pc: ('PC', Icons.desktop_windows), T.laptop: ('Laptop', Icons.laptop), T.server: ('Server', Icons.dns),
  T.phone: ('Smartphone', Icons.smartphone), T.printer: ('Printer', Icons.print), T.ipPhone: ('IP Phone', Icons.phone_in_talk),
  T.swSensor: ('Saklar', Icons.toggle_off), T.motion: ('Sensor Gerak', Icons.directions_run), T.lamp: ('Lampu', Icons.lightbulb_outline),
  T.alarm: ('Alarm', Icons.notifications_off), T.iotGw: ('IoT Gateway', Icons.device_hub),
  T.firewall: ('Firewall', Icons.security), T.cloud: ('Cloud', Icons.cloud), T.modem: ('Modem', Icons.settings_input_component),
  T.tablet: ('Tablet', Icons.tablet_mac), T.smartTv: ('Smart TV', Icons.tv), T.ipCam: ('IP Camera', Icons.videocam),
  T.tempSensor: ('Sensor Suhu', Icons.thermostat), T.doorLock: ('Door Lock', Icons.lock), T.fan: ('Kipas Angin', Icons.toys),
};
const tSub = {T.firewall: 'ASA', T.cloud: 'WAN / Internet', T.modem: 'DSL / Cable', T.ipCam: 'CCTV', T.tempSensor: 'DHT11', T.fan: 'Fan / AC'};
List<(String, String, Color)> get cbl => [
  ('Straight', 'Garis hitam lurus', kFg2), ('Crossover', 'Merah putus-putus', Colors.redAccent),
  ('Fiber', 'Garis kuning', Colors.amber), ('Console', 'Garis biru', kAcc),
  ('Wireless', 'Putus-putus melengkung (ke AP)', Colors.cyanAccent),
];

bool netDev(T t) => const {T.router, T.sw, T.hub, T.ap, T.wlc, T.firewall, T.cloud, T.modem}.contains(t); // perangkat jaringan
bool passive(T t) => const {T.sw, T.hub, T.ap, T.wlc, T.firewall, T.cloud, T.modem}.contains(t); // meneruskan frame (firewall transparan, cloud = WAN)
bool iot(T t) => const {T.swSensor, T.motion, T.lamp, T.alarm, T.iotGw, T.tempSensor, T.doorLock, T.fan}.contains(t); // perangkat IoT
bool sensor(T t) => const {T.swSensor, T.motion, T.tempSensor}.contains(t); // sumber sinyal
bool actuator(T t) => const {T.lamp, T.alarm, T.doorLock, T.fan}.contains(t); // penerima sinyal
/// Apakah device sudah terkonfigurasi? Switch/Hub/AP/IoT tidak butuh config (selalu siap).
bool cfg(Dev d) {
  if (d.t == T.router) return d.ifs.values.any((i) => i.up && ipn(i.ip) != null);
  if (netDev(d.t) || iot(d.t)) return true;
  return ipn(d.ip) != null && ipn(d.mask) != null;
}

bool lit(Dev d) => iot(d.t) && d.t != T.iotGw && d.on; // lagi aktif (bersinar)

/// Teks status di bawah nama perangkat IoT.
String stateLabel(Dev d) => switch (d.t) {
      T.tempSensor => '${d.temp.round()}°C',
      T.doorLock => d.on ? 'TERBUKA' : 'TERKUNCI',
      _ => d.on ? 'ON' : 'OFF',
    };

/// Warna indikator perangkat IoT saat aktif.
Color stateColor(Dev d) => switch (d.t) {
      T.lamp => const Color(0xFFFFEB3B), T.alarm => Colors.redAccent, T.swSensor => Colors.greenAccent, T.motion => Colors.orangeAccent, T.tempSensor => Colors.deepOrangeAccent, T.doorLock => Colors.lightGreenAccent, T.fan => Colors.lightBlueAccent, _ => kAcc,
    };

/// Icon device (icon IoT berubah sesuai ON/OFF).
IconData icn(Dev d) => switch (d.t) {
      T.swSensor => d.on ? Icons.toggle_on : Icons.toggle_off,
      T.lamp => d.on ? Icons.lightbulb : Icons.lightbulb_outline,
      T.alarm => d.on ? Icons.notifications_active : Icons.notifications_off,
      T.motion => Icons.directions_run,
      T.tempSensor => Icons.thermostat,
      T.doorLock => d.on ? Icons.lock_open : Icons.lock,
      T.fan => Icons.toys,
      _ => tInfo[d.t]!.$2,
    };

/// Ubah "192.168.1.1" jadi angka. Null kalau format salah.
int? ipn(String s) {
  final x = s.trim().split('.');
  if (x.length != 4) return null;
  var r = 0;
  for (final e in x) {
    final n = int.tryParse(e);
    if (n == null || n < 0 || n > 255) return null;
    r = r * 256 + n;
  }
  return r;
}

/// Ubah angka jadi teks IP.
String ips(int v) => '${v >> 24 & 255}.${v >> 16 & 255}.${v >> 8 & 255}.${v & 255}';

/// Cek apakah dua IP satu jaringan berdasarkan subnet mask.
bool same(String a, String b, String mk) {
  final x = ipn(a), y = ipn(b), k = ipn(mk);
  return x != null && y != null && k != null && (x & k) == (y & k);
}

/// Hitung panjang prefix (/24) dari subnet mask.
int pre(String mk) {
  var k = ipn(mk) ?? 0, n = 0;
  while (k > 0) { n += k & 1; k >>= 1; }
  return n;
}

class Iface { String ip = '', mask = '255.255.255.0'; bool up = false; }

/// Satu port FastEthernet pada switch: status admin (Up/Down) dan VLAN akses.
class SwPort { bool up = true; int vlan = 1; }

/// Data satu device di canvas.
class Dev {
  int id; T t; String name; Offset pos;
  String ip = '', mask = '255.255.255.0', gw = '';
  final Map<String, Iface> ifs = {};
  final List<List<String>> routes = []; // rute statis router: [network, mask, next-hop]
  final List<SwPort> ports = []; // 24 port switch (Fa0/1 - Fa0/24)
  String dns = ''; // DNS server
  bool wifi = false; double range = 200; // Wi-Fi: memancar atau tidak (AP selalu), radius sinyal dalam px
  final List<String> log = [];
  bool on = false; // status IoT: sensor aktif / aktuator menyala
  double temp = 25, thr = 30; // Sensor Suhu: suhu terbaca & batas aktif (derajat C)
  bool dhcp = false, useDhcp = false; // dhcp = layanan DHCP di Server, useDhcp = client minta IP otomatis
  String pool = '192.168.1.100', dgw = ''; int poolSize = 50; // pengaturan pool DHCP
  int mode = 0; String cur = ''; // mode CLI router: 0 user, 1 priv, 2 config, 3 config-if
  Dev(this.id, this.t, this.name, this.pos) {
    if (t == T.router) { ifs['g0/0'] = Iface(); ifs['g0/1'] = Iface(); }
    if (t == T.sw) for (var i = 0; i < 24; i++) ports.add(SwPort());
    if (t == T.ap) wifi = true;
  }
  Map toJ() => {'id': id, 't': t.index, 'n': name, 'x': pos.dx, 'y': pos.dy, 'ip': ip, 'mk': mask, 'gw': gw, 'on': on, 'dh': dhcp, 'ud': useDhcp, 'pl': pool, 'ps': poolSize, 'dg': dgw, 'rt': routes, 'tp': temp, 'th': thr, 'dn': dns, 'wf': wifi, 'rg': range, 'sp': t == T.sw ? ports.map((p) => [p.up ? 1 : 0, p.vlan]).toList() : null,
        'ifs': ifs.map((k, v) => MapEntry(k, [v.ip, v.mask, v.up]))};
  static Dev fromJ(Map j) {
    final d = Dev(j['id'], T.values[j['t']], j['n'], Offset(j['x'], j['y']))..ip = j['ip']..mask = j['mk']..gw = j['gw']..on = j['on'] ?? false..dhcp = j['dh'] ?? false..useDhcp = j['ud'] ?? false..pool = j['pl'] ?? '192.168.1.100'..poolSize = j['ps'] ?? 50..dgw = j['dg'] ?? ''..temp = (j['tp'] ?? 25).toDouble()..thr = (j['th'] ?? 30).toDouble();
    (j['ifs'] as Map).forEach((k, v) => d.ifs[k] = Iface()..ip = v[0]..mask = v[1]..up = v[2]);
    for (final e in (j['rt'] ?? []) as List) d.routes.add(List<String>.from(e));
    d.dns = j['dn'] ?? '';
    d.wifi = j['wf'] ?? d.t == T.ap;
    d.range = (j['rg'] ?? 200).toDouble();
    final sp = j['sp'];
    if (sp is List) for (var i = 0; i < sp.length && i < d.ports.length; i++) { d.ports[i].up = sp[i][0] == 1; d.ports[i].vlan = sp[i][1]; }
    return d;
  }
}

class Link { int a, b, c, pa = 0, pb = 0; Link(this.a, this.b, this.c); } // c = jenis kabel (0-4); pa/pb = nomor port switch di ujung a/b (0 = bukan switch)
class Note { Offset pos; String text; Note(this.pos, this.text); }
/// Hasil ping / paket yang dianimasikan. phases: urutan paket (ARP lalu ICMP, atau DHCP).
class PR {
  bool ok; String msg; List<int> path;
  String proto = 'ICMP'; List<String> phases = ['ICMP'];
  String sIp = '', dIp = ''; int sId = -1, dId = -1, arpLen = 2; // arpLen = jumlah node yang dilewati ARP (sampai router/host pertama)
  PR(this.ok, this.msg, this.path);
}

/// Satu soal Lab Challenge: skenario jaringan bermasalah + pasangan (id sumber, id tujuan) yang harus berhasil di-ping.
class Chal {
  final String id, title, desc, hint;
  final void Function() build;
  final List<(int, int)> goals;
  Chal(this.id, this.title, this.desc, this.hint, this.build, this.goals);
}

/// Kabel wireless hanya aktif kalau klien berada di dalam radius sinyal AP / Router Wi-Fi.
bool linkUp(Link l, Dev a, Dev b) {
  if (l.c != 4) return true;
  final src = a.wifi ? a : (b.wifi ? b : null);
  if (src == null) return true; // kabel wireless antar IoT: tidak dibatasi radius
  final cl = identical(src, a) ? b : a;
  return (src.pos - cl.pos).distance <= src.range;
}

/// Validasi IP: kosong = wajib diisi, format salah = pesan error, null = valid.
String? ipErr(String v) => v.trim().isEmpty ? 'Wajib diisi' : (ipn(v) == null ? 'Format IP salah (contoh 192.168.1.10)' : null);

/// Validasi subnet mask (harus bit 1 berurutan).
String? maskErr(String v) {
  if (v.trim().isEmpty) return 'Wajib diisi';
  final m = ipn(v);
  if (m == null) return 'Format salah (contoh 255.255.255.0)';
  final inv = ~m & 0xFFFFFFFF;
  return (inv & (inv + 1)) == 0 ? null : 'Subnet mask tidak valid';
}

/// MAC address palsu tapi konsisten per perangkat (dan per interface untuk router).
String mac(Dev d, [int i = 0]) {
  String h(int v) => (v & 255).toRadixString(16).toUpperCase().padLeft(2, '0');
  return '00:1A:${h(d.id)}:${h(d.id * 37 + 11)}:${h(i + 1)}:${h(d.id * 7 + i * 3 + 5)}';
}

/// IP milik perangkat d yang menghadap ke perangkat o (router punya banyak interface).
String ipFacing(Dev d, Dev o) {
  if (d.t != T.router) return d.ip;
  final cands = o.t == T.router ? o.ifs.values.map((i) => i.ip).toList() : [o.ip];
  for (final i in d.ifs.values) if (cands.any((c) => same(i.ip, c, i.mask))) return i.ip;
  return d.ifs.values.firstOrNull?.ip ?? '';
}

/// Nomor interface router yang menghadap ke perangkat o (untuk MAC).
int ifIdx(Dev d, Dev o) {
  if (d.t != T.router) return 0;
  final ip = ipFacing(d, o);
  return math.max(0, d.ifs.values.toList().indexWhere((i) => i.ip == ip));
}

/// Posisi paket pada saat t (0..1): titik, indeks hop, dan fase (0 = ARP/pertama). Dipakai painter & hit-test tap.
({Offset p, int hop, int ph})? pktAt(PR? r, Map<int, Dev> mp, double t) {
  if (r == null || r.path.length < 2 || !r.path.every(mp.containsKey)) return null;
  final np = r.phases.length;
  final double g = t.clamp(0.0, 0.9999).toDouble() * np;
  final ph = g.floor(), lt = g - ph;
  final ids = r.phases[ph] == 'ARP' ? r.path.take(r.arpLen).toList() : r.path;
  if (ids.length < 2) return null;
  final pts = ids.map((i) => mp[i]!.pos + _o).toList(), n = pts.length - 1;
  final f = (lt * n).clamp(0.0, n - 0.0001).toDouble(), i = f.floor();
  return (p: Offset.lerp(pts[i], pts[i + 1], f - i)!, hop: i, ph: ph);
}

/// Titik awal aplikasi: layar boleh berputar bebas (portrait & landscape).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Kalau ada widget yang error, tampilkan teks error-nya (bukan layar abu-abu kosong) supaya gampang dilacak
  ErrorWidget.builder = (d) => Directionality(
      textDirection: TextDirection.ltr,
      child: Material(color: Colors.black, child: SingleChildScrollView(padding: const EdgeInsets.all(16),
          child: Text('Terjadi error:\n${d.exception}\n\n${d.stack}', style: const TextStyle(color: Colors.redAccent, fontSize: 11)))));
  SystemChrome.setPreferredOrientations(DeviceOrientation.values); // auto-rotate penuh
  try { // muat pengaturan tema & grid (tidak boleh bikin aplikasi macet)
    final sp = await SharedPreferences.getInstance().timeout(const Duration(seconds: 3));
    themeIdx.value = (sp.getInt('theme') ?? 0).clamp(0, 2);
    showGrid.value = sp.getBool('grid') ?? true;
  } catch (_) {}
  runApp(const ReyzApp());
}

class ReyzApp extends StatelessWidget {
  const ReyzApp({super.key});
  @override
  Widget build(BuildContext c) => ValueListenableBuilder<int>(
      valueListenable: themeIdx,
      builder: (_, i, __) => MaterialApp(
          title: 'Reyz Tracer Simulation', debugShowCheckedModeBanner: false,
          theme: (i == 2 ? ThemeData.light(useMaterial3: true) : ThemeData.dark(useMaterial3: true)).copyWith(
              scaffoldBackgroundColor: kBg,
              bottomSheetTheme: BottomSheetThemeData(backgroundColor: kCard, modalBackgroundColor: kCard, surfaceTintColor: Colors.transparent),
              colorScheme: i == 2 ? ColorScheme.light(primary: kAcc, surface: kCard) : ColorScheme.dark(primary: kAcc, surface: kCard)),
          home: const Sim()));
}

class Sim extends StatefulWidget {
  const Sim({super.key});
  @override
  State<Sim> createState() => SimState();
}

class SimState extends State<Sim> with SingleTickerProviderStateMixin {
  final devs = <Dev>[], notes = <Note>[];
  final links = <Link>[];
  final ctrl = TransformationController();
  late final AnimationController an = AnimationController(vsync: this);
  Tool tool = Tool.select;
  int cable = 0, nid = 1;
  int? first; // device pertama (untuk kabel / ping)
  PR? run; // paket yang sedang beranimasi
  final arped = <String>{}; // pasangan (pengirim>tujuan) yang sudah ARP, jadi ping berikutnya tanpa ARP
  Dev? lastSrv; // server DHCP terakhir yang memberi IP
  Offset? tbPos; double? tbScale; double tbBase = 1, tbAuto = 1; Offset tbDef = const Offset(8, 8); // toolbar mengambang: posisi & ukuran
  Chal? chal; final chalDone = <String>{}; // Lab Challenge aktif & yang sudah selesai

  @override
  void initState() {
    super.initState();
    an.addStatusListener(onPktDone);
    loadChal();
  }

  @override
  void dispose() {
    an.dispose();
    ctrl.dispose();
    super.dispose();
  }

  /// Animasi paket selesai: catat ARP, bersihkan paket, tampilkan hasil.
  void onPktDone(AnimationStatus st) {
    final r = run;
    if (st != AnimationStatus.completed || r == null) return;
    if (r.proto == 'ICMP') arped.add('${r.sId}>${r.dId}');
    setState(() => run = null);
    toast(true, r.msg);
  }

  Dev byId(int id) => devs.firstWhere((d) => d.id == id);

  /// Tambah device baru ke daftar.
  Dev add(T t, Offset p, {String ip = '', String gw = ''}) {
    final n = devs.where((d) => d.t == t).length + 1;
    final d = Dev(nid++, t, '${tInfo[t]!.$1}${tInfo[t]!.$1.contains(' ') ? ' ' : ''}$n', p)..ip = ip..gw = gw;
    devs.add(d);
    return d;
  }

  /// Tetangga device lewat kabel data (kabel console tidak membawa data).
  List<int> nbrs(int id) => links.where((l) => l.c != 3 && linkOn(l) && (l.a == id || l.b == id)).map((l) => l.a == id ? l.b : l.a).toList();

  /// Apakah kabel l aktif? (kabel wireless mati kalau klien di luar radius sinyal)
  bool linkOn(Link l) => linkUp(l, byId(l.a), byId(l.b));

  Dev? dev(int id) => devs.where((d) => d.id == id).firstOrNull;

  /// Nomor port switch (1-24) di ujung kabel l yang menempel ke switch `id`; diberikan otomatis (port kosong terkecil).
  int portOf(Link l, int id) {
    if (byId(id).t != T.sw) return 0;
    final isA = l.a == id;
    var p = isA ? l.pa : l.pb;
    if (p == 0) {
      final used = links.where((x) => x != l && (x.a == id || x.b == id)).map((x) => x.a == id ? x.pa : x.pb).toSet();
      p = 1;
      while (used.contains(p)) p++;
      if (isA) l.pa = p; else l.pb = p;
    }
    return p;
  }

  /// Pastikan semua kabel yang menempel ke switch sudah punya nomor port (urut sesuai pembuatan kabel).
  void fixPorts() { for (final l in links) { portOf(l, l.a); portOf(l, l.b); } }

  /// Konfigurasi port switch sw di ujung kabel l (null kalau melebihi 24 port).
  SwPort? portAt(Dev sw, Link l) { final p = portOf(l, sw.id); return p >= 1 && p <= sw.ports.length ? sw.ports[p - 1] : null; }

  /// Cari jalur Layer 2 dari a ke b lewat switch/hub/AP/dll. Setiap switch memeriksa port: harus Up, dan VLAN sisi masuk = sisi keluar.
  List<int>? l2(int a, int b) {
    fixPorts();
    final start = (a, 0); // (id device, VLAN yang terbawa; 0 = belum ditentukan)
    final prev = <(int, int), (int, int)?>{start: null};
    final q = [start];
    while (q.isNotEmpty) {
      final cur = q.removeAt(0), u = cur.$1, vl = cur.$2;
      if (u == b) {
        final r = <int>[];
        var k = cur;
        while (true) { r.add(k.$1); final p = prev[k]; if (p == null) break; k = p; }
        return r.reversed.toList();
      }
      final du = byId(u);
      if (u != a && !passive(du.t)) continue;
      for (final l in links.where((x) => x.c != 3 && (x.a == u || x.b == u) && linkOn(x)).toList()) {
        final v = l.a == u ? l.b : l.a, dv = byId(v);
        var nv = vl;
        if (du.t == T.sw && u != a) { // keluar lewat port switch u
          final pe = portAt(du, l);
          if (pe == null || !pe.up || pe.vlan != vl) continue;
        }
        if (dv.t == T.sw) { // masuk lewat port switch v
          final pi = portAt(dv, l);
          if (pi == null || !pi.up || (vl != 0 && pi.vlan != vl)) continue;
          nv = pi.vlan;
        }
        final nk = (v, nv);
        if (!prev.containsKey(nk)) { prev[nk] = cur; q.add(nk); }
      }
    }
    return null;
  }

  /// Cari jalur dari router r sampai ke device target (IP dst), lewat rute connected atau ip route (maks 8 router).
  List<int>? routeVia(Dev r, String dst, Dev target) {
    var cur = r;
    final path = <int>[r.id];
    for (var hop = 0; hop < 8; hop++) {
      if (cur.ifs.values.any((i) => i.up && same(i.ip, dst, i.mask))) {
        final p = l2(cur.id, target.id);
        return p == null ? null : [...path, ...p.skip(1)];
      }
      final rt = cur.routes.where((x) => same(dst, x[0], x[1])).firstOrNull ?? (ipn(cur.gw) != null ? <String>['0.0.0.0', '0.0.0.0', cur.gw] : null);
      if (rt == null) return null;
      final nh = devs.where((e) => e.t == T.router && e != cur && e.ifs.values.any((i) => i.up && i.ip == rt[2])).firstOrNull;
      if (nh == null || !cur.ifs.values.any((i) => i.up && same(i.ip, rt[2], i.mask))) return null;
      final p = l2(cur.id, nh.id);
      if (p == null) return null;
      path.addAll(p.skip(1));
      cur = nh;
    }
    return null;
  }

  /// INTI SIMULASI: logika ping palsu tapi logis (satu jaringan = sukses, beda = lewat gateway/router).
  PR ping(Dev s, String sip, String smk, String sgw, String dst) {
    if (sip.isEmpty) return PR(false, 'Gagal! ${s.name} belum punya IP Address', []);
    if (ipn(dst) == null) return PR(false, 'Gagal! Format IP tujuan salah', []);
    final d = devs.where((e) => e.ip == dst || e.ifs.values.any((i) => i.ip == dst)).firstOrNull;
    if (d == null) return PR(false, 'Gagal! IP $dst tidak ada di topologi, cek IP Address tujuan', []);
    if (d.t == T.router && !d.ifs.values.any((i) => i.ip == dst && i.up)) return PR(false, 'Gagal! Interface router $dst masih shutdown (no shutdown dulu)', []);
    if (same(sip, dst, smk)) {
      final p = l2(s.id, d.id);
      if (p == null) return PR(false, 'Gagal! ${s.name} ke ${d.name} belum tersambung (cek kabel, port/VLAN switch, atau jangkauan Wi-Fi)', []);
      return PR(true, 'Berhasil! Ping dari ${s.name} ke ${d.name} Reply', p)..sIp = sip..dIp = dst..sId = s.id..dId = d.id;
    }
    if (sgw.isEmpty) return PR(false, 'Gagal! Beda jaringan, isi Gateway di ${s.name}', []);
    if (!same(sip, sgw, smk)) return PR(false, 'Gagal! Gateway $sgw beda jaringan dengan ${s.name}', []);
    final r = devs.where((e) => e.t == T.router && e.ifs.values.any((i) => i.ip == sgw && i.up)).firstOrNull;
    if (r == null) return PR(false, 'Gagal! Gateway $sgw tidak ditemukan / interface router belum no shutdown', []);
    final p1 = l2(s.id, r.id);
    if (p1 == null) return PR(false, 'Gagal! ${s.name} belum tersambung ke router gateway (cek kabel, port/VLAN, Wi-Fi)', []);
    final p2 = routeVia(r, dst, d);
    if (p2 == null) return PR(false, 'Gagal! ${r.name} tidak punya rute ke $dst (cek ip address, no shutdown, kabel, dan ip route)', []);
    if (d.t != T.router && d.gw.isEmpty) return PR(false, 'Gagal! Gateway ${d.name} kosong, balasan tidak bisa kembali', []);
    // balasan harus bisa kembali: router terakhir di sisi tujuan harus punya rute ke pengirim
    final last = p2.map(byId).lastWhere((x) => x.t == T.router, orElse: () => r);
    if (routeVia(last, sip, s) == null) return PR(false, 'Gagal! Paket sampai, tapi balasan tidak bisa kembali: ${last.name} tidak punya rute ke $sip (tambah ip route)', []);
    return PR(true, 'Berhasil! Ping dari ${s.name} ke ${d.name} Reply (via ${r.name})', [...p1, ...p2.skip(1)])..sIp = sip..dIp = dst..sId = s.id..dId = d.id;
  }

  /// Ping dari device s ke IP dst (otomatis pilih IP sumber, khusus router pakai interface).
  PR pingDev(Dev s, String dst) {
    var ip = s.ip, mk = s.mask, gw = s.gw;
    if (s.t == T.router) {
      final u = s.ifs.values.where((i) => i.ip.isNotEmpty && i.up).toList();
      final f = u.where((x) => same(x.ip, dst, x.mask)).firstOrNull ?? u.firstOrNull;
      ip = f?.ip ?? ''; mk = f?.mask ?? '255.255.255.0'; gw = '';
    }
    return ping(s, ip, mk, gw, dst);
  }

  /// Teks output ping ala Command Prompt.
  String pingOut(Dev s, String dst) {
    final r = pingDev(s, dst);
    final h = 'Pinging $dst with 32 bytes of data:\n';
    if (r.ok) return '$h${List.filled(4, 'Reply from $dst: bytes=32 time<1ms TTL=128').join('\n')}\n\nPing statistics: Sent=4, Received=4, Lost=0 (0% loss)';
    return '$h${List.filled(4, 'Request timed out.').join('\n')}\n\nPing statistics: Sent=4, Received=0, Lost=4 (100% loss)\n[Petunjuk] ${r.msg}';
  }

  /// Prompt CLI sesuai mode.
  String prompt(Dev d) {
    if (d.t != T.router) return 'C:\\> ';
    final n = d.name.replaceAll(' ', '');
    return ['$n>', '$n#', '$n(config)#', '$n(config-if)#'][d.mode] + ' ';
  }

  /// Output tabel rute (hanya rute connected).
  String routes(Dev d) {
    final r = d.ifs.entries.where((e) => e.value.up && ipn(e.value.ip) != null).map((e) {
      final i = e.value;
      return 'C    ${ips(ipn(i.ip)! & ipn(i.mask)!)}/${pre(i.mask)} is directly connected, ${e.key}';
    }).toList();
    r.addAll(d.routes.map((x) => 'S    ${x[0]}/${pre(x[1])} [1/0] via ${x[2]}'));
    return r.isEmpty ? '(Belum ada rute. Atur ip address lalu no shutdown)' : 'Codes: C - connected, S - static\n\n${r.join('\n')}';
  }

  /// Menjalankan perintah CLI (PC = Command Prompt, Router = CLI palsu).
  String cli(Dev d, String raw) {
    if (raw.trim().isEmpty) return '';
    var w = raw.trim().toLowerCase().split(RegExp(r'\s+'));
    if (d.t != T.router) {
      if (w[0] == 'ping') return w.length < 2 ? 'Pemakaian: ping <ip>' : pingOut(d, w[1]);
      if (w[0] == 'ipconfig') {
        if (w.length > 1 && w[1] == '/release') { d.ip = ''; d.gw = ''; return 'IP Address dilepas.'; }
        if (w.length > 1 && w[1] == '/renew') {
          d.useDhcp = true;
          final r = dhcpRequest(d);
          return r == null ? 'DHCP gagal: tidak ada server DHCP aktif yang terhubung' : 'DHCP berhasil. IP baru: $r';
        }
        return 'DHCP . . . . . . . . : ${d.useDhcp ? 'Aktif' : 'Tidak'}\nIPv4 Address. . . . : ${d.ip}\nSubnet Mask . . . . : ${d.mask}\nDefault Gateway . . : ${d.gw}\nDNS Server. . . . . : ${d.dns}';
      }
      if (w[0] == 'cls') return '\u0000';
      return 'Perintah tidak dikenal. Coba: ping, ipconfig, ipconfig /renew, ipconfig /release, cls';
    }
    var m = d.mode;
    const bad = '% Perintah salah atau belum di mode yang benar';
    if (w[0] == 'do') {
      if (m < 2 || w.length < 2) return bad;
      w = w.sublist(1); m = 1;
    }
    switch (w[0]) {
      case 'enable':
        if (m == 0) { d.mode = 1; return ''; }
        return bad;
      case 'exit':
        d.mode = d.mode > 0 ? d.mode - 1 : 0; return '';
      case 'end':
        if (d.mode >= 2) d.mode = 1;
        return '';
      case 'conf':
        if (m == 1) { d.mode = 2; return 'Enter configuration commands, one per line. End with CNTL/Z.'; }
        return bad;
      case 'hostname':
        if (m >= 2 && w.length > 1) { d.name = raw.trim().split(RegExp(r'\s+'))[1]; return ''; }
        return bad;
      case 'interface':
      case 'int':
        {
          if (m < 2 || w.length < 2) return bad;
          final mt = RegExp(r'(\d+/\d+)$').firstMatch(w.sublist(1).join(''));
          final k = mt == null ? '' : 'g${mt.group(1)}';
          if (!d.ifs.containsKey(k)) return '% Interface tidak ada. Pakai g0/0 atau g0/1';
          d.cur = k; d.mode = 3; return '';
        }
      case 'ip':
        {
          if (m >= 2 && w.length >= 5 && w[1] == 'route') { // ip route <network> <mask> <next-hop>
            if (ipn(w[2]) == null || ipn(w[3]) == null || ipn(w[4]) == null) return '% Format salah. Contoh: ip route 192.168.2.0 255.255.255.0 10.0.0.2';
            d.routes..removeWhere((x) => x[0] == w[2] && x[1] == w[3])..add([w[2], w[3], w[4]]);
            return '';
          }
          if (m != 3 || w.length < 4 || w[1] != 'address') return bad;
          if (ipn(w[2]) == null || ipn(w[3]) == null) return '% Format IP atau subnet mask salah';
          d.ifs[d.cur]!..ip = w[2]..mask = w[3];
          return '';
        }
      case 'no':
        if (m == 3 && w.length > 1 && w[1] == 'shutdown') { d.ifs[d.cur]!.up = true; return '%LINK-5-CHANGED: Interface ${d.cur}, changed state to up'; }
        return bad;
      case 'shutdown':
        if (m == 3) { d.ifs[d.cur]!.up = false; return '%LINK-5-CHANGED: Interface ${d.cur}, changed state to administratively down'; }
        return bad;
      case 'ping':
        return m >= 1 && w.length > 1 ? pingOut(d, w[1]) : bad;
      case 'show':
        if (m >= 1 && w.length >= 3 && w[1] == 'ip' && w[2] == 'route') return routes(d);
        return bad;
    }
    return bad;
  }

  /// Tampilkan notifikasi hijau (sukses) / merah (gagal).
  void toast(bool ok, String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700));

  /// Jalankan paket (ping / DHCP) dengan animasi; ping pertama didahului ARP. Hasil muncul di onPktDone.
  void runPing(PR r) {
    if (!r.ok || r.path.length < 2) { toast(r.ok, r.msg); return; }
    if (r.proto == 'ICMP') r.phases = arped.contains('${r.sId}>${r.dId}') ? ['ICMP'] : ['ARP', 'ICMP'];
    var k = 1;
    while (k < r.path.length - 1 && passive(byId(r.path[k]).t)) k++;
    r.arpLen = k + 1; // ARP hanya sampai node Layer 3 pertama (host tujuan / gateway)
    setState(() => run = r);
    an.duration = Duration(milliseconds: 700 * (r.path.length - 1) * r.phases.length);
    an.forward(from: 0);
  }

  /// Pause / lanjutkan animasi paket.
  void togglePause() {
    if (an.isAnimating) { an.stop(); } else { an.forward(); }
    setState(() {});
  }

  /// Apakah sentuhan mengenai paket yang sedang bergerak?
  bool hitPacket(Offset p) {
    final at = pktAt(run, {for (final d in devs) d.id: d}, an.value);
    return at != null && (at.p - p).distance <= 34 / ctrl.value.getMaxScaleOnAxis();
  }

  /// PACKET INSPECTOR: detail header Layer 2 / Layer 3 / protokol dari paket yang sedang dipantau (animasi dijeda selama dibuka).
  Future<void> inspect() async {
    final r = run;
    if (r == null) return;
    final mp = {for (final d in devs) d.id: d};
    final at = pktAt(r, mp, an.value);
    if (at == null) return;
    final was = an.isAnimating;
    an.stop();
    setState(() {});
    final path = r.path, ph = r.phases[at.ph];
    var p3 = at.hop;
    while (p3 > 0 && passive(mp[path[p3]]!.t)) p3--;
    var n3 = at.hop + 1;
    while (n3 < path.length - 1 && passive(mp[path[n3]]!.t)) n3++;
    final a = mp[path[p3]]!, b = mp[path[n3]]!; // ujung segmen Layer 2 yang sedang dilewati
    final ttl = 128 - path.take(p3 + 1).where((i) => mp[i]!.t == T.router).length;
    final rows = <(String, List<(String, String)>)>[
      ('Posisi paket', [('Hop', '${mp[path[at.hop]]!.name} -> ${mp[path[at.hop + 1]]!.name}'), ('Protokol', ph == 'ICMP' ? 'ICMP (Echo Request)' : (ph == 'ARP' ? 'ARP (Request)' : 'DHCP (Discover)'))]),
      ('Layer 2 - Ethernet II', [
        ('Source MAC', mac(a, ifIdx(a, b))),
        ('Dest MAC', ph == 'ICMP' ? mac(b, ifIdx(b, a)) : 'FF:FF:FF:FF:FF:FF (broadcast)'),
        ('EtherType', ph == 'ARP' ? '0x0806 (ARP)' : '0x0800 (IPv4)'),
      ]),
      if (ph == 'ARP')
        ('Layer 3 - ARP', [('Sender IP', ipFacing(a, b)), ('Target IP', ipFacing(b, a)), ('Info', 'Who has ${ipFacing(b, a)}? Tell ${ipFacing(a, b)}')])
      else if (ph == 'DHCP')
        ('Layer 3 - IPv4', [('Source IP', '0.0.0.0'), ('Dest IP', '255.255.255.255'), ('Protocol', '17 (UDP 68 -> 67)'), ('Info', 'DHCP Discover dari ${a.name}')])
      else
        ('Layer 3 - IPv4', [('Source IP', r.sIp), ('Dest IP', r.dIp), ('TTL', '$ttl'), ('Protocol', '1 (ICMP, Type 8 Echo Request)')]),
    ];
    await showDialog(context: context, builder: (_) => AlertDialog(
        backgroundColor: kCard, surfaceTintColor: Colors.transparent, title: const Text('Packet Inspector'),
        content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          for (final sec in rows) ...[
            Padding(padding: const EdgeInsets.only(top: 10, bottom: 4), child: Text(sec.$1, style: TextStyle(color: kAcc, fontWeight: FontWeight.bold))),
            for (final kv in sec.$2)
              Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 100, child: Text(kv.$1, style: TextStyle(color: kFg2, fontSize: 12))),
                Expanded(child: SelectableText(kv.$2, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
              ])),
          ],
        ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))]));
    if (was && run == r && mounted) an.forward();
    if (mounted) setState(() {});
  }

  /// Kirim PDU/ping dari device s ke device d.
  void pduTo(Dev s, Dev d) {
    final dip = d.t == T.router ? (d.ifs.values.where((i) => i.ip.isNotEmpty).firstOrNull?.ip ?? '') : d.ip;
    if (dip.isEmpty) { toast(false, 'Gagal! ${d.name} belum punya IP Address'); return; }
    runPing(pingDev(s, dip));
  }

  /// Tombol PLAY: ping otomatis antara 2 end device pertama.
  void play() {
    final e = devs.where((d) => !netDev(d.t) && !iot(d.t)).toList();
    if (e.length < 2) { toast(false, 'Tambah minimal 2 end device dulu'); return; }
    pduTo(e[0], e[1]);
  }

  /// DHCP: client minta IP ke Server DHCP yang satu jaringan (Layer 2). Return IP yang didapat, null kalau gagal.
  String? dhcpRequest(Dev c) {
    for (final sv in devs.where((x) => x != c && x.t == T.server && x.dhcp && ipn(x.ip) != null)) {
      if (l2(c.id, sv.id) == null) continue;
      final base = ipn(sv.pool);
      if (base == null) continue;
      for (var i = 0; i < sv.poolSize; i++) {
        final cand = ips(base + i);
        final used = cand == sv.ip || devs.any((x) => x != c && (x.ip == cand || x.ifs.values.any((f) => f.ip == cand)));
        if (!used) { c.ip = cand; c.mask = sv.mask; c.gw = sv.dgw; c.dns = sv.dns; lastSrv = sv; return cand; }
      }
    }
    return null;
  }

  /// Client DHCP yang belum punya IP otomatis meminta IP.
  /// Mengembalikan paket DHCP (untuk dianimasikan) milik client pertama yang berhasil dapat IP.
  PR? autoDhcp() {
    PR? firstLease;
    for (final c in devs.where((x) => x.useDhcp && x.ip.isEmpty).toList()) {
      if (dhcpRequest(c) == null) continue;
      final srv = lastSrv!;
      firstLease ??= (PR(true, 'DHCP: ${c.name} mendapat IP ${c.ip} dari ${srv.name}', l2(c.id, srv.id) ?? [])
        ..proto = 'DHCP'..phases = ['DHCP']..sIp = '0.0.0.0'..dIp = '255.255.255.255'..sId = c.id..dId = srv.id);
    }
    return firstLease;
  }

  /// Refresh umum: DHCP + trigger IoT + tampilan.
  void touch() => setState(() { autoDhcp(); propagate(); });

  /// Cek update di GitHub Releases. Kalau ada versi baru, buka link download APK (install menimpa versi lama, data tetap).
  Future<void> checkUpdate() async {
    final sp = await SharedPreferences.getInstance();
    final repo = await ask('Repo GitHub (user/repo)', sp.getString('repo') ?? '');
    if (repo == null || !repo.contains('/')) return;
    await sp.setString('repo', repo);
    toast(true, 'Mengecek update...');
    try {
      final rq = await HttpClient().getUrl(Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
      rq.headers.set('User-Agent', 'ReyzTracer');
      final rs = await rq.close();
      final j = jsonDecode(await rs.transform(utf8.decoder).join());
      if (j['tag_name'] == null) { toast(false, 'Belum ada release di repo itu (cek nama repo / jalankan build dulu)'); return; }
      final n = int.tryParse('${j['tag_name']}'.replaceAll(RegExp(r'\D'), '')) ?? 0;
      final apk = (j['assets'] as List).map((a) => '${a['browser_download_url']}').firstWhere((u) => u.endsWith('.apk'), orElse: () => '');
      if (!mounted) return;
      if (n <= kBuild || apk.isEmpty) { toast(true, 'Sudah versi terbaru (build $kBuild)'); return; }
      showDialog(context: context, builder: (_) => AlertDialog(
          backgroundColor: kCard, surfaceTintColor: Colors.transparent, title: const Text('Update tersedia'),
          content: Text('Build $n sudah tersedia (kamu: build $kBuild). Tekan Update, download APK-nya, lalu buka file-nya untuk memperbarui. Data projek tetap aman.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Nanti')),
            FilledButton(onPressed: () { Navigator.pop(context); launchUrl(Uri.parse(apk), mode: LaunchMode.externalApplication); }, child: const Text('Update')),
          ]));
    } catch (e) {
      if (mounted) toast(false, 'Gagal cek update: cek internet / nama repo');
    }
  }

  // ===== Riwayat Undo / Redo =====
  final undoSt = <String>[], redoSt = <String>[];
  bool eraseCable = false; // mode Hapus: false = hapus perangkat, true = hapus kabel saja

  /// Foto kondisi canvas saat ini (JSON).
  String snap() => jsonEncode(toJ());

  /// Catat kondisi canvas SEBELUM sebuah perubahan (tambah/hapus, kabel, geser, rename, template).
  void rec() {
    undoSt.add(snap());
    if (undoSt.length > 60) undoSt.removeAt(0);
    redoSt.clear();
  }

  /// Dipakai halaman config: catat kondisi awal ke riwayat kalau ada yang berubah.
  void commit(String before) {
    if (before.isEmpty || snap() == before) return;
    undoSt.add(before);
    if (undoSt.length > 60) undoSt.removeAt(0);
    redoSt.clear();
    Future.microtask(() { if (mounted) setState(() {}); });
  }

  /// Undo: kembali ke langkah sebelumnya.
  void undo() {
    if (undoSt.isEmpty) return;
    redoSt.add(snap());
    fromJ(jsonDecode(undoSt.removeLast()), focus: false);
  }

  /// Redo: maju lagi ke langkah setelah undo.
  void redo() {
    if (redoSt.isEmpty) return;
    undoSt.add(snap());
    fromJ(jsonDecode(redoSt.removeLast()), focus: false);
  }

  /// Jarak titik p ke garis a-b.
  double segDist(Offset p, Offset a, Offset b) {
    final ab = b - a, len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = len2 == 0 ? 0.0 : ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2;
    return (p - (a + ab * t.clamp(0.0, 1.0).toDouble())).distance;
  }

  /// Jarak titik p ke kabel l (kabel wireless berbentuk kurva).
  double linkDist(Offset p, Link l) {
    final a = byId(l.a).pos + _o, b = byId(l.b).pos + _o;
    if (l.c != 4) return segDist(p, a, b);
    final v = b - a, m = (a + b) / 2;
    final double len = v.distance == 0 ? 1.0 : v.distance;
    final c = m + Offset(-v.dy, v.dx) / len * 40; // titik kontrol kurva (sama dengan painter)
    var best = double.infinity, prev = a;
    for (var i = 1; i <= 24; i++) {
      final t = i / 24, u = 1 - t, q = a * (u * u) + c * (2 * u * t) + b * (t * t);
      best = math.min(best, segDist(p, prev, q));
      prev = q;
    }
    return best;
  }

  /// Mode Hapus Kabel: putuskan kabel yang paling dekat dengan titik sentuh (perangkat tidak ikut terhapus).
  void eraseLinkAt(Offset p) {
    final lim = 22 / ctrl.value.getMaxScaleOnAxis();
    Link? best;
    var bd = lim;
    for (final l in links) {
      final dd = linkDist(p, l);
      if (dd <= bd) { bd = dd; best = l; }
    }
    final hit = best;
    if (hit == null) return;
    final a = byId(hit.a).name, b = byId(hit.b).name;
    rec();
    setState(() { links.remove(hit); propagate(); });
    toast(true, 'Kabel $a - $b diputus');
  }

  /// Kosongkan canvas (tercatat di undo) dan keluar dari challenge yang aktif.
  void reset() { rec(); chal = null; fromJ({'devs': [], 'links': [], 'notes': []}); }

  /// Geser tampilan canvas supaya semua device kelihatan.
  void focusAll() {
    if (devs.isEmpty) return;
    final x = devs.map((d) => d.pos.dx).reduce(math.min), y = devs.map((d) => d.pos.dy).reduce(math.min);
    ctrl.value = Matrix4.translationValues(-(x - 60), -(y - 80), 0);
  }

  /// Konfirmasi dulu kalau canvas berisi, sebelum diganti template / file import.
  Future<void> confirmLoad(VoidCallback f) async {
    if (devs.isNotEmpty) {
      final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
          backgroundColor: kCard, surfaceTintColor: Colors.transparent, title: const Text('Ganti canvas?'),
          content: const Text('Topologi sekarang akan diganti. Simpan dulu lewat Save / Export kalau masih dibutuhkan.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Lanjut')),
          ]));
      if (ok != true) return;
    }
    f();
  }

  /// EXPORT .rts: seluruh topologi (device, posisi, kabel, IP, nama, catatan) jadi JSON lalu disimpan sebagai file .rts.
  Future<void> exportRts() async {
    final name = await ask('Nama file (.rts)', 'projek');
    if (name == null || name.isEmpty) return;
    final data = jsonEncode({'app': 'ReyzTracer', 'fmt': 1, 'ver': kVersion, 'saved': DateTime.now().toIso8601String(), ...toJ()});
    try {
      final p = await FilePicker.platform.saveFile(
          dialogTitle: 'Simpan projek', fileName: '${name.replaceAll(RegExp(r'[^\w\- ]'), '')}.rts', bytes: Uint8List.fromList(utf8.encode(data)));
      if (p != null && mounted) toast(true, 'Projek berhasil di-export');
    } catch (e) {
      if (mounted) toast(false, 'Gagal export: $e');
    }
  }

  /// IMPORT .rts: baca file, validasi, lalu render ulang topologi ke canvas.
  Future<void> importRts() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      final f = r?.files.single;
      if (f == null || f.bytes == null) return;
      final j = jsonDecode(utf8.decode(f.bytes!));
      if (j is! Map || j['devs'] is! List || j['links'] is! List) throw 'bukan file .rts';
      rec();
      fromJ(j);
      if (mounted) toast(true, 'Projek "${f.name}" dimuat');
    } catch (e) {
      if (mounted) toast(false, 'Gagal import: file tidak valid');
    }
  }

  /// EXPORT PNG: gambar ulang topologi (hanya area yang berisi device) ke gambar, lalu simpan.
  Future<void> exportPng() async {
    if (devs.isEmpty && notes.isEmpty) { toast(false, 'Canvas masih kosong'); return; }
    try {
      final rects = [for (final d in devs) d.pos & const Size(72, 86), for (final n in notes) n.pos & const Size(216, 70)];
      var b = rects.first;
      for (final x in rects.skip(1)) b = b.expandToInclude(x);
      b = b.inflate(50);
      final pr = math.min(2.0, 4096 / math.max(b.width, b.height));
      final rec = ui.PictureRecorder(), cv = Canvas(rec);
      cv.scale(pr);
      cv.translate(-b.left, -b.top);
      cv.drawRect(b, Paint()..color = kBg);
      Pt(devs, links, null, 0).paint(cv, const Size(6000, 6000)); // grid + kabel
      for (final d in devs) {
        final c = d.pos + _o, box = ui.RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: 60, height: 60), const Radius.circular(16));
        final col = lit(d) ? stateColor(d) : kAcc, ic = icn(d);
        if (lit(d)) cv.drawRRect(box, Paint()..color = col.withAlpha(150)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
        cv.drawRRect(box, Paint()..color = kCard);
        cv.drawRRect(box, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = col);
        final icol = iot(d.t) ? (d.t == T.iotGw ? kAcc : (d.on ? stateColor(d) : Colors.grey)) : (netDev(d.t) ? kAcc : kFg);
        txt(cv, String.fromCharCode(ic.codePoint), c, TextStyle(fontFamily: ic.fontFamily, package: ic.fontPackage, fontSize: 32, color: icol));
        txt(cv, d.name, d.pos + const Offset(36, 70), TextStyle(fontSize: 11, color: kFg));
        if (iot(d.t) && d.t != T.iotGw) txt(cv, stateLabel(d), d.pos + const Offset(36, 83), TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: d.on ? stateColor(d) : Colors.grey));
      }
      for (final n in notes) {
        final tp = TextPainter(text: TextSpan(text: n.text, style: const TextStyle(fontSize: 12, color: Colors.white)), textDirection: TextDirection.ltr)..layout(maxWidth: 184);
        final box = ui.RRect.fromRectAndRadius(Rect.fromLTWH(n.pos.dx, n.pos.dy, tp.width + 16, tp.height + 16), const Radius.circular(8));
        cv.drawRRect(box, Paint()..color = const Color(0xFF3A3410));
        cv.drawRRect(box, Paint()..style = PaintingStyle.stroke..color = Colors.amber);
        tp.paint(cv, n.pos + const Offset(8, 8));
      }
      final img = await rec.endRecording().toImage((b.width * pr).round(), (b.height * pr).round());
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      final p = await FilePicker.platform.saveFile(dialogTitle: 'Simpan gambar topologi', fileName: 'topologi_${DateTime.now().millisecondsSinceEpoch}.png', bytes: bd!.buffer.asUint8List());
      if (p != null && mounted) toast(true, 'Gambar topologi tersimpan');
    } catch (e) {
      if (mounted) toast(false, 'Gagal export gambar: $e');
    }
  }

  /// Menu Berkas: export / import .rts dan export gambar.
  void files() => showModalBottomSheet(context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640),
      builder: (ctx) => ListView(shrinkWrap: true, children: [
            ListTile(dense: true, title: Text('Berkas Projek', style: TextStyle(color: kAcc))),
            ListTile(dense: true, leading: const Icon(Icons.upload_file), title: const Text('Export projek (.rts)'), subtitle: const Text('Simpan topologi ke file'), onTap: () { Navigator.pop(ctx); exportRts(); }),
            ListTile(dense: true, leading: const Icon(Icons.file_open), title: const Text('Import projek (.rts)'), subtitle: const Text('Muat topologi dari file'), onTap: () { Navigator.pop(ctx); confirmLoad(importRts); }),
            ListTile(dense: true, leading: const Icon(Icons.image), title: const Text('Export canvas ke gambar (PNG)'), subtitle: const Text('Pilih folder, misalnya Pictures'), onTap: () { Navigator.pop(ctx); exportPng(); }),
          ]));

  /// Template Basic LAN: 1 Switch, 2 PC, 1 Printer (192.168.1.0/24).
  void tplLan() {
    reset();
    final sw = add(T.sw, const Offset(420, 260));
    final a = add(T.pc, const Offset(160, 120), ip: '192.168.1.10'), b = add(T.pc, const Offset(160, 400), ip: '192.168.1.11');
    final p = add(T.printer, const Offset(680, 260), ip: '192.168.1.20');
    setState(() {
      for (final x in [a, b, p]) links.add(Link(x.id, sw.id, 0));
      notes.add(Note(const Offset(160, 40), 'Basic LAN 192.168.1.0/24. Coba: PC1 > Command Prompt > ping 192.168.1.11'));
    });
    focusAll();
  }

  /// Template Router to Router: 2 router (kabel crossover), 2 subnet PC, ip route sudah terpasang.
  void tplRouter() {
    reset();
    final a = add(T.pc, const Offset(80, 260), ip: '192.168.1.2', gw: '192.168.1.1');
    final s1 = add(T.sw, const Offset(280, 260)), r1 = add(T.router, const Offset(500, 260));
    final r2 = add(T.router, const Offset(760, 260)), s2 = add(T.sw, const Offset(980, 260));
    final b = add(T.pc, const Offset(1180, 260), ip: '192.168.2.2', gw: '192.168.2.1');
    void ifc(Dev r, String k, String ip, String mk) => r.ifs[k]!..ip = ip..mask = mk..up = true;
    ifc(r1, 'g0/0', '192.168.1.1', '255.255.255.0');
    ifc(r1, 'g0/1', '10.0.0.1', '255.255.255.252');
    ifc(r2, 'g0/0', '10.0.0.2', '255.255.255.252');
    ifc(r2, 'g0/1', '192.168.2.1', '255.255.255.0');
    r1.routes.add(['192.168.2.0', '255.255.255.0', '10.0.0.2']);
    r2.routes.add(['192.168.1.0', '255.255.255.0', '10.0.0.1']);
    setState(() {
      links..add(Link(a.id, s1.id, 0))..add(Link(s1.id, r1.id, 0))..add(Link(r1.id, r2.id, 1))..add(Link(r2.id, s2.id, 0))..add(Link(s2.id, b.id, 0));
      notes.add(Note(const Offset(300, 140), 'Subnet 1: 192.168.1.0/24, Subnet 2: 192.168.2.0/24, link router 10.0.0.0/30. Coba: PC1 ping 192.168.2.2. Lihat rute: Router > CLI > enable, show ip route'));
    });
    focusAll();
  }

  /// Template Smart Home IoT: 1 IoT Gateway, 1 Sensor Gerak, 1 Lampu, 1 Alarm.
  void tplIot() {
    reset();
    final mo = add(T.motion, const Offset(150, 260)), gw = add(T.iotGw, const Offset(450, 260));
    final la = add(T.lamp, const Offset(750, 140)), al = add(T.alarm, const Offset(750, 380));
    setState(() {
      links..add(Link(mo.id, gw.id, 4))..add(Link(gw.id, la.id, 4))..add(Link(gw.id, al.id, 4));
      notes.add(Note(const Offset(150, 100), 'Smart Home: tap Sensor Gerak untuk ON/OFF, Lampu & Alarm ikut berubah.'));
    });
    focusAll();
  }

  /// Menu Lab Templates (template baru + lab latihan).
  void templates() => showModalBottomSheet(context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640),
      builder: (ctx) => ListView(shrinkWrap: true, children: [
            ListTile(dense: true, title: Text('Lab Templates', style: TextStyle(color: kAcc))),
            for (final t in [
              ('Basic LAN', '1 Switch, 2 PC, 1 Printer', Icons.lan, tplLan),
              ('Router to Router', '2 Router, 2 subnet PC, ip route', Icons.router, tplRouter),
              ('Smart Home IoT', 'Gateway, Sensor Gerak, Lampu, Alarm', Icons.home, tplIot),
              ('Lab 2 PC 1 Switch', 'Latihan ping dasar', Icons.science, lab1),
              ('Lab 2 Jaringan 1 Router', 'Latihan CLI router', Icons.science, lab2),
              ('Lab IoT Saklar & Lampu', 'Saklar dan Sensor Gerak', Icons.lightbulb, lab3),
              ('Lab DHCP Server & 2 PC', 'Latihan DHCP', Icons.settings_ethernet, lab4),
            ])
              ListTile(dense: true, leading: Icon(t.$3), title: Text(t.$1), subtitle: Text(t.$2), onTap: () { Navigator.pop(ctx); confirmLoad(t.$4); }),
          ]));

  /// Ganti tema lalu simpan pilihan.
  Future<void> setTheme(int i) async {
    themeIdx.value = i;
    setState(() {});
    (await SharedPreferences.getInstance()).setInt('theme', i);
  }

  /// Pengaturan: tema (Biru / Hitam / Putih), grid, kosongkan canvas.
  void settings() => showModalBottomSheet(context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640),
      builder: (ctx) => StatefulBuilder(builder: (_, ss) => ListView(shrinkWrap: true, children: [
            ListTile(dense: true, title: Text('Tema Aplikasi', style: TextStyle(color: kAcc))),
            for (var i = 0; i < 3; i++)
              ListTile(
                  dense: true, title: Text(const ['Biru Dongker (default)', 'Hitam', 'Putih'][i]),
                  trailing: themeIdx.value == i ? Icon(Icons.check, color: kAcc) : null,
                  onTap: () { Navigator.pop(ctx); setTheme(i); }),
            SwitchListTile(dense: true, title: const Text('Tampilkan grid'), value: showGrid.value, onChanged: (v) async {
              showGrid.value = v; setState(() {}); ss(() {});
              (await SharedPreferences.getInstance()).setBool('grid', v);
            }),
            ListTile(dense: true, leading: const Icon(Icons.system_update), title: const Text('Cek Update aplikasi'), subtitle: Text('Versi $kVersion (build $kBuild)'), onTap: () { Navigator.pop(ctx); checkUpdate(); }),
            ListTile(dense: true, leading: const Icon(Icons.layers_clear), title: const Text('Kosongkan canvas'), onTap: () { Navigator.pop(ctx); reset(); }),
          ])));

  /// LOGIKA TRIGGER IoT: status tiap Lampu/Alarm = ON kalau ada sensor ON yang terhubung (langsung atau lewat IoT Gateway).
  void propagate() {
    for (final a in devs.where((d) => actuator(d.t))) {
      final seen = {a.id}, q = [a.id];
      var on = false;
      while (q.isNotEmpty) {
        final u = q.removeAt(0);
        for (final v in nbrs(u)) {
          if (!seen.add(v)) continue;
          final x = byId(v);
          if (sensor(x.t)) { if (x.on) on = true; } else if (x.t == T.iotGw) q.add(v);
        }
      }
      a.on = on;
    }
  }

  /// Aksi saat device di-tap, tergantung tool aktif.
  void tap(Dev d) {
    switch (tool) {
      case Tool.delete:
        if (eraseCable) { toast(false, 'Mode Hapus Kabel: tap garis kabelnya, bukan perangkat'); return; }
        rec();
        setState(() { devs.remove(d); links.removeWhere((l) => l.a == d.id || l.b == d.id); run = null; propagate(); });
      case Tool.cable:
        if (first == null) { setState(() => first = d.id); return; }
        final a = first!;
        setState(() => first = null);
        if (a == d.id) return;
        if (links.any((l) => (l.a == a && l.b == d.id) || (l.a == d.id && l.b == a))) { toast(false, 'Kedua device sudah terhubung'); return; }
        final ap = byId(a).t == T.ap || d.t == T.ap || byId(a).t == T.wlc || d.t == T.wlc || iot(byId(a).t) || iot(d.t);
        if (cable == 4 && !ap) { toast(false, 'Kabel wireless harus ke Access Point atau perangkat IoT'); return; }
        for (final x in [byId(a), d]) {
          if (x.t == T.sw && links.where((l) => l.a == x.id || l.b == x.id).length >= 24) { toast(false, 'Semua port ${x.name} sudah terpakai (maks 24)'); return; }
        }
        rec();
        PR? lease;
        setState(() { links.add(Link(a, d.id, cable)); propagate(); lease = autoDhcp(); });
        final ls = lease;
        if (ls != null) runPing(ls); // animasi paket DHCP Discover

      case Tool.ping:
        if (first == null) { setState(() => first = d.id); return; }
        final s = byId(first!);
        setState(() => first = null);
        if (s != d) pduTo(s, d);
      default:
        if (!iot(d.t)) { Navigator.push(context, MaterialPageRoute(builder: (_) => DevDialog(d, this, touch))); return; }
        if (tool == Tool.select && sensor(d.t)) { setState(() { d.on = !d.on; if (d.t == T.tempSensor) d.temp = d.on ? d.thr + 5 : d.thr - 5; propagate(); }); return; } // tap sensor = toggle ON/OFF
        showDialog(context: context, builder: (_) => IotDialog(d, this, touch));
    }
  }

  Future<String?> ask(String title, String init) {
    final c = TextEditingController(text: init);
    return showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(scrollable: true, backgroundColor: kCard, surfaceTintColor: Colors.transparent, title: Text(title), content: TextField(controller: c, autofocus: true), actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
              FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('OK')),
            ]));
  }

  /// Tambah catatan teks di canvas.
  Future<void> addNote(Offset o) async {
    final t = await ask('Catatan', '');
    if (t != null && t.isNotEmpty) { rec(); setState(() => notes.add(Note(o, t))); }
  }

  /// Tekan lama device: ganti nama / hapus.
  void menu(Dev d) => showModalBottomSheet(context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(leading: const Icon(Icons.edit), title: const Text('Ganti nama'), onTap: () async {
              Navigator.pop(context);
              final n = await ask('Nama device', d.name);
              if (n != null && n.isNotEmpty) { rec(); setState(() => d.name = n); }
            }),
            ListTile(leading: const Icon(Icons.delete, color: Colors.redAccent), title: const Text('Hapus device'), onTap: () {
              Navigator.pop(context);
              rec();
              setState(() { devs.remove(d); links.removeWhere((l) => l.a == d.id || l.b == d.id); propagate(); });
            }),
          ]));

  /// Taruh device baru di tengah layar.
  void spawn(T t) {
    final sz = MediaQuery.of(context).size, k = (devs.length % 4) * 24.0;
    final c = ctrl.toScene(Offset(sz.width / 2, sz.height / 3));
    rec();
    setState(() => add(t, c + Offset(k, k) - _o));
  }

  Widget grid(List<T> l) => GridView.count(crossAxisCount: math.max(3, math.min(6, (MediaQuery.of(context).size.width / 120).floor())), childAspectRatio: 1.3, children: [
        for (final t in l)
          InkWell(onTap: () { Navigator.pop(context); spawn(t); }, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(tInfo[t]!.$2, color: kAcc, size: 32), const SizedBox(height: 4), Text(tInfo[t]!.$1, style: const TextStyle(fontSize: 12)),
            if (tSub[t] != null) Text(tSub[t]!, style: TextStyle(fontSize: 9, color: kFg2)),
          ])),
      ]);

  /// Toolbox: 3 tab (Network Devices, End Devices, IoT & Sensor).
  void addSheet() => showModalBottomSheet(context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => DefaultTabController(length: 3, child: SizedBox(height: MediaQuery.of(context).orientation == Orientation.portrait ? 380 : 250, child: Column(children: [
            const TabBar(tabs: [Tab(text: 'Network Devices'), Tab(text: 'End Devices'), Tab(text: 'IoT & Sensor')]),
            Expanded(child: TabBarView(children: [
              grid(T.values.where(netDev).toList()),
              grid(T.values.where((t) => !netDev(t) && !iot(t)).toList()),
              grid(T.values.where(iot).toList()),
            ])),
          ]))));

  /// Pilih jenis kabel lalu tap 2 device.
  void cableSheet() => showModalBottomSheet(context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => ListView(shrinkWrap: true, children: [
            for (var i = 0; i < cbl.length; i++)
              ListTile(
                  dense: true, leading: Icon(Icons.timeline, color: cbl[i].$3), title: Text('Kabel ${cbl[i].$1}'), subtitle: Text(cbl[i].$2),
                  onTap: () { Navigator.pop(context); setState(() { cable = i; tool = Tool.cable; first = null; }); }),
          ]));

  Map toJ() => {
        'devs': devs.map((d) => d.toJ()).toList(), 'links': links.map((l) => [l.a, l.b, l.c, l.pa, l.pb]).toList(),
        'notes': notes.map((n) => [n.pos.dx, n.pos.dy, n.text]).toList(),
      };

  /// Muat topologi dari JSON.
  void fromJ(Map j, {bool focus = true}) => setState(() {
        devs..clear()..addAll((j['devs'] as List).map((e) => Dev.fromJ(e)));
        links..clear()..addAll((j['links'] as List).map((e) => Link(e[0], e[1], e[2])..pa = (e.length > 3 ? e[3] : 0)..pb = (e.length > 4 ? e[4] : 0)));
        notes..clear()..addAll(((j['notes'] ?? []) as List).map((e) => Note(Offset(e[0], e[1]), e[2])));
        nid = devs.fold(0, (m, d) => d.id > m ? d.id : m) + 1;
        first = null; run = null; arped.clear(); an.stop(); propagate(); autoDhcp(); if (focus) focusAll();
      });

  /// Simpan topologi ke memori HP.
  Future<void> save() async {
    final n = await ask('Nama projek', 'Projek ${DateTime.now().millisecondsSinceEpoch % 1000}');
    if (n == null || n.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('p_$n', jsonEncode(toJ()));
    toast(true, 'Projek "$n" tersimpan');
  }

  /// Lab 1: 2 PC + 1 Switch (sudah dikonfigurasi, tinggal ping).
  void lab1() {
    reset();
    final a = add(T.pc, const Offset(120, 250), ip: '192.168.1.1'), s = add(T.sw, const Offset(360, 250));
    final b = add(T.pc, const Offset(600, 250), ip: '192.168.1.2');
    setState(() => links..add(Link(a.id, s.id, 0))..add(Link(s.id, b.id, 0)));
  }

  /// Lab 2: 2 jaringan + 1 Router (router belum dikonfigurasi, latihan CLI).
  void lab2() {
    reset();
    final a = add(T.pc, const Offset(80, 300), ip: '192.168.1.2', gw: '192.168.1.1');
    final s1 = add(T.sw, const Offset(260, 300)), r = add(T.router, const Offset(450, 300)), s2 = add(T.sw, const Offset(640, 300));
    final b = add(T.pc, const Offset(820, 300), ip: '192.168.2.2', gw: '192.168.2.1');
    setState(() {
      links..add(Link(a.id, s1.id, 0))..add(Link(s1.id, r.id, 0))..add(Link(r.id, s2.id, 0))..add(Link(s2.id, b.id, 0));
      notes.add(Note(const Offset(300, 180), 'Setting router: g0/0 = 192.168.1.1, g0/1 = 192.168.2.1'));
    });
  }

  /// Lab IoT: Saklar & Sensor Gerak -> Gateway -> Lampu & Alarm.
  void lab3() {
    reset();
    final sw = add(T.swSensor, const Offset(150, 200)), mo = add(T.motion, const Offset(150, 420));
    final gw = add(T.iotGw, const Offset(450, 310)), la = add(T.lamp, const Offset(750, 200)), al = add(T.alarm, const Offset(750, 420));
    setState(() {
      links..add(Link(sw.id, gw.id, 0))..add(Link(mo.id, gw.id, 0))..add(Link(gw.id, la.id, 0))..add(Link(gw.id, al.id, 0));
      notes.add(Note(const Offset(150, 100), 'Tap Saklar / Sensor Gerak untuk ON-OFF. Lampu & Alarm ikut berubah.'));
    });
  }

  /// Lab DHCP: 1 Server DHCP + 2 PC yang minta IP otomatis.
  void lab4() {
    reset();
    final sv = add(T.server, const Offset(120, 250), ip: '192.168.1.1')..dhcp = true..pool = '192.168.1.100'..poolSize = 20..dgw = '192.168.1.1';
    final sw = add(T.sw, const Offset(380, 250));
    final a = add(T.pc, const Offset(640, 150));
    final b = add(T.pc, const Offset(640, 350));
    a.useDhcp = true;
    b.useDhcp = true;
    setState(() {
      links..add(Link(sv.id, sw.id, 0))..add(Link(sw.id, a.id, 0))..add(Link(sw.id, b.id, 0));
      autoDhcp();
      notes.add(Note(const Offset(120, 130), 'PC1 & PC2 pakai DHCP. Buka PC > Command Prompt, coba: ipconfig lalu ping 192.168.1.1'));
    });
  }

  /// Daftar contoh lab + projek tersimpan.
  Future<void> projects() async {
    final sp = await SharedPreferences.getInstance();
    final ks = sp.getKeys().where((k) => k.startsWith('p_')).toList();
    if (!mounted) return;
    showModalBottomSheet(context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640), builder: (_) => ListView(shrinkWrap: true, children: [
          ListTile(title: Text('Contoh Lab', style: TextStyle(color: kAcc))),
          ListTile(leading: const Icon(Icons.science), title: const Text('Lab 2 PC 1 Switch'), onTap: () { Navigator.pop(context); lab1(); }),
          ListTile(leading: const Icon(Icons.science), title: const Text('Lab 2 Jaringan 1 Router'), onTap: () { Navigator.pop(context); lab2(); }),
          ListTile(leading: const Icon(Icons.lightbulb), title: const Text('Lab IoT Saklar & Lampu'), onTap: () { Navigator.pop(context); lab3(); }),
          ListTile(leading: const Icon(Icons.settings_ethernet), title: const Text('Lab DHCP Server & 2 PC'), onTap: () { Navigator.pop(context); lab4(); }),
          ListTile(title: Text('Projek tersimpan', style: TextStyle(color: kAcc))),
          for (final k in ks)
            ListTile(
                title: Text(k.substring(2)), onTap: () { Navigator.pop(context); rec(); fromJ(jsonDecode(sp.getString(k)!)); },
                trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { sp.remove(k); Navigator.pop(context); })),
        ]));
  }

  String hint() => switch (tool) {
        Tool.select => 'Geser device / tap: setting IP atau ON-OFF sensor', Tool.hand => 'Geser canvas dengan 1 jari',
        Tool.delete => eraseCable ? 'Hapus Kabel: tap garis kabel (perangkat tetap ada)' : 'Hapus Perangkat: tap device (kabelnya ikut terhapus)', Tool.inspect => 'Tap device untuk lihat config',
        Tool.note => 'Tap canvas untuk tambah catatan', Tool.ping => first == null ? 'Ping: pilih device asal' : 'Ping: pilih device tujuan',
        Tool.cable => first == null ? 'Kabel ${cbl[cable].$1}: pilih device pertama' : 'Pilih device kedua',
      };

  /// Gambar satu device (icon flat + nama), bisa di-drag.
  Widget devW(Dev d) => Positioned(
      left: d.pos.dx, top: d.pos.dy, width: 72,
      child: GestureDetector(
        onTap: () => tap(d), onLongPress: () => menu(d),
        onPanStart: tool == Tool.select ? (_) => rec() : null,
        onPanUpdate: tool == Tool.select ? (u) => setState(() { d.pos += u.delta / ctrl.value.getMaxScaleOnAxis(); autoDhcp(); }) : null,
        child: Column(children: [
          Container(
              width: 60, height: 60,
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: first == d.id ? kFg : (lit(d) ? stateColor(d) : kAcc), width: 1.5),
                  boxShadow: [BoxShadow(color: (lit(d) ? stateColor(d) : kAcc).withAlpha(lit(d) ? 190 : 60), blurRadius: lit(d) ? 28 : 12, spreadRadius: lit(d) ? 4 : 0)]),
              child: Icon(icn(d), size: 32, color: iot(d.t) ? (d.t == T.iotGw ? kAcc : (d.on ? stateColor(d) : Colors.grey)) : (netDev(d.t) ? kAcc : kFg))),
          const SizedBox(height: 4),
          Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
          if (wifiState(d) != null) Text(wifiState(d)! ? 'Wi-Fi terhubung' : 'Wi-Fi terputus', style: TextStyle(fontSize: 9, color: wifiState(d)! ? Colors.green : Colors.red)),
          if (iot(d.t) && d.t != T.iotGw) Text(stateLabel(d), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: d.on ? stateColor(d) : Colors.grey)),
        ]),
      ));

  Widget noteW(Note n) => Positioned(
      left: n.pos.dx, top: n.pos.dy,
      child: GestureDetector(
          onLongPress: () { rec(); setState(() => notes.remove(n)); },
          child: Container(
              padding: const EdgeInsets.all(8), constraints: const BoxConstraints(maxWidth: 200),
              decoration: BoxDecoration(color: const Color(0xFF3A3410), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.amber)),
              child: Text(n.text, style: const TextStyle(fontSize: 12, color: Colors.white)))));

  // ===================== WI-FI =====================
  /// Status Wi-Fi perangkat nirkabel: true = terhubung, false = terputus (di luar radius), null = tidak punya kabel wireless ke AP/Router Wi-Fi.
  bool? wifiState(Dev d) {
    for (final l in links.where((x) => x.c == 4 && (x.a == d.id || x.b == d.id))) {
      final o = byId(l.a == d.id ? l.b : l.a);
      if (o.wifi && !d.wifi) return linkOn(l);
    }
    return null;
  }

  // ===================== LAB CHALLENGES =====================
  void wire(Dev a, Dev b, [int c = 0]) => links.add(Link(a.id, b.id, c));

  /// Challenge 1: Subnet Mask PC1 salah (/30) padahal satu LAN /24.
  void ch1() {
    reset();
    final a = add(T.pc, const Offset(150, 220), ip: '192.168.1.10'), sw = add(T.sw, const Offset(420, 220)), b = add(T.pc, const Offset(690, 220), ip: '192.168.1.20');
    a.mask = '255.255.255.252'; // SALAH
    setState(() { wire(a, sw); wire(sw, b); notes.add(Note(const Offset(150, 100), 'Kabel sudah benar, tapi PC1 tidak bisa ping PC2. Cari kesalahannya!')); });
    focusAll();
  }

  /// Challenge 2: kabel PC2 ke switch belum terpasang.
  void ch2() {
    reset();
    final a = add(T.pc, const Offset(150, 220), ip: '192.168.1.10'), sw = add(T.sw, const Offset(420, 220));
    add(T.pc, const Offset(690, 220), ip: '192.168.1.20');
    setState(() { wire(a, sw); notes.add(Note(const Offset(150, 100), 'PC1 tidak bisa ping PC2. Ada kabel yang belum terpasang.')); });
    focusAll();
  }

  /// Challenge 3: Default Gateway PC1 dan PC2 tertukar.
  void ch3() {
    reset();
    final a = add(T.pc, const Offset(80, 260), ip: '192.168.1.10', gw: '192.168.2.1'); // gateway tertukar
    final s1 = add(T.sw, const Offset(280, 260)), r = add(T.router, const Offset(500, 260)), s2 = add(T.sw, const Offset(720, 260));
    final b = add(T.pc, const Offset(920, 260), ip: '192.168.2.10', gw: '192.168.1.1');
    r.ifs['g0/0']!..ip = '192.168.1.1'..up = true;
    r.ifs['g0/1']!..ip = '192.168.2.1'..up = true;
    setState(() { wire(a, s1); wire(s1, r); wire(r, s2); wire(s2, b); notes.add(Note(const Offset(80, 140), 'Dua LAN dihubungkan router, tapi PC1 tidak bisa ping PC2.')); });
    focusAll();
  }

  /// Challenge 4: port Fa0/1 dan Fa0/2 beda VLAN.
  void ch4() {
    reset();
    final a = add(T.pc, const Offset(150, 220), ip: '192.168.1.10'), sw = add(T.sw, const Offset(420, 220)), b = add(T.pc, const Offset(690, 220), ip: '192.168.1.20');
    sw.ports[0].vlan = 10;
    sw.ports[1].vlan = 20;
    setState(() { wire(a, sw); wire(sw, b); notes.add(Note(const Offset(150, 100), 'Satu switch, satu subnet, tapi PC1 dan PC2 tidak bisa saling ping.')); });
    focusAll();
  }

  /// Challenge 5: Smartphone di luar jangkauan Wi-Fi.
  void ch5() {
    reset();
    final srv = add(T.server, const Offset(100, 250), ip: '192.168.1.5'), sw = add(T.sw, const Offset(320, 250)), ap = add(T.ap, const Offset(540, 250));
    final ph = add(T.phone, const Offset(880, 320), ip: '192.168.1.20');
    setState(() { wire(srv, sw); wire(sw, ap); wire(ph, ap, 4); notes.add(Note(const Offset(100, 120), 'Smartphone tidak bisa ping Server. Perhatikan heatmap sinyal.')); });
    focusAll();
  }

  /// Challenge 6: dua router belum punya rute statis.
  void ch6() {
    tplRouter();
    setState(() {
      for (final r in devs.where((x) => x.t == T.router)) r.routes.clear();
      notes..clear()..add(Note(const Offset(300, 140), 'PC1 tidak bisa ping PC2: router belum tahu jaringan seberang. Pakai CLI router.'));
    });
  }

  /// Daftar soal Lab Challenges.
  List<Chal> get chals => [
        Chal('subnet', '1. Subnet Mask Salah', 'PC1 tidak bisa ping PC2 padahal kabel benar.', 'Buka PC1 > Config. Satu LAN 192.168.1.0/24 memakai mask 255.255.255.0.', ch1, [(1, 3)]),
        Chal('kabel', '2. Kabel Terputus', 'PC2 tidak terhubung ke jaringan.', 'Pakai tombol Kabel untuk menyambungkan PC2 ke switch.', ch2, [(1, 3)]),
        Chal('gateway', '3. Gateway Terbalik', 'Dua LAN lewat router, tapi PC tidak bisa saling ping.', 'Gateway PC = IP router di jaringannya sendiri: PC1 pakai 192.168.1.1, PC2 pakai 192.168.2.1.', ch3, [(1, 5)]),
        Chal('vlan', '4. VLAN Beda', 'PC1 dan PC2 satu switch tapi tidak bisa ping.', 'Buka Switch > Config, cek VLAN port Fa0/1 dan Fa0/2, lalu samakan.', ch4, [(1, 3)]),
        Chal('wifi', '5. Di Luar Jangkauan Wi-Fi', 'Smartphone tidak bisa ping Server.', 'Lihat heatmap: geser Smartphone masuk ke lingkaran sinyal Access Point.', ch5, [(4, 1)]),
        Chal('route', '6. Rute Statis Hilang', 'Dua router belum saling mengenal jaringan.', 'CLI R1: conf t, ip route 192.168.2.0 255.255.255.0 10.0.0.2. CLI R2: ip route 192.168.1.0 255.255.255.0 10.0.0.1.', ch6, [(1, 6)]),
      ];

  /// Muat daftar challenge yang sudah selesai.
  Future<void> loadChal() async {
    try {
      final sp = await SharedPreferences.getInstance();
      chalDone.addAll(sp.getStringList('chal_done') ?? []);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// Challenge selesai: simpan dan beri notifikasi.
  Future<void> chalSolved(Chal c) async {
    if (chal?.id != c.id || chalDone.contains(c.id)) return;
    chalDone.add(c.id);
    if (mounted) { setState(() {}); toast(true, 'Challenge selesai: ${c.title}'); }
    try { (await SharedPreferences.getInstance()).setStringList('chal_done', chalDone.toList()); } catch (_) {}
  }

  /// VALIDASI OTOMATIS: apakah ping dari device a ke b sukses saat ini?
  bool goalOk(int a, int b) {
    final s = dev(a), d = dev(b);
    if (s == null || d == null) return false;
    final dip = d.t == T.router ? (d.ifs.values.where((i) => i.ip.isNotEmpty).firstOrNull?.ip ?? '') : d.ip;
    return dip.isNotEmpty && pingDev(s, dip).ok;
  }

  /// Tombol "Tes Ping": jalankan ping target (animasi) atau tampilkan alasan gagalnya.
  void testGoals() {
    final c = chal;
    if (c == null) return;
    for (final g in c.goals) {
      final s = dev(g.$1), d = dev(g.$2);
      if (s == null || d == null) { toast(false, 'Perangkat target sudah dihapus'); return; }
      if (!goalOk(g.$1, g.$2)) { pduTo(s, d); return; }
    }
    pduTo(dev(c.goals.first.$1)!, dev(c.goals.first.$2)!);
  }

  /// Menu Lab Challenges.
  void challenges() => showModalBottomSheet(
      context: context, backgroundColor: kCard, isScrollControlled: true, useSafeArea: true, constraints: const BoxConstraints(maxWidth: 640),
      builder: (ctx) => ListView(shrinkWrap: true, children: [
            ListTile(dense: true, title: Text('Lab Challenges', style: TextStyle(color: kAcc, fontWeight: FontWeight.bold)), subtitle: Text('Selesai ${chalDone.length} dari ${chals.length}. Perbaiki jaringan sampai ping target berhasil.')),
            for (final c in chals)
              ListTile(
                  dense: true, leading: Icon(chalDone.contains(c.id) ? Icons.check_circle : Icons.flag, color: chalDone.contains(c.id) ? Colors.green : kAcc),
                  title: Text(c.title), subtitle: Text(c.desc),
                  onTap: () { Navigator.pop(ctx); confirmLoad(() { c.build(); setState(() => chal = c); }); }),
          ]));

  /// Bar challenge di atas canvas: judul, indikator ping target (live), tes ping, petunjuk, keluar.
  Widget challengeBar() {
    final c = chal!;
    final st = [for (final g in c.goals) goalOk(g.$1, g.$2)];
    final ok = st.isNotEmpty && st.every((x) => x);
    if (ok && !chalDone.contains(c.id)) WidgetsBinding.instance.addPostFrameCallback((_) => chalSolved(c));
    String nm(int id) => dev(id)?.name ?? '?';
    return Material(
        color: ok ? Colors.green.shade800 : kCard,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), child: Row(children: [
          Icon(ok ? Icons.emoji_events : Icons.flag, color: ok ? Colors.amber : kAcc),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ok ? '${c.title} - SELESAI' : c.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            Wrap(spacing: 10, children: [
              for (var i = 0; i < c.goals.length; i++)
                Text('Ping ${nm(c.goals[i].$1)} -> ${nm(c.goals[i].$2)}: ${st[i] ? 'SUCCESS' : 'FAILED'}', style: TextStyle(fontSize: 11, color: st[i] ? Colors.lightGreenAccent : Colors.redAccent)),
            ]),
          ])),
          IconButton(tooltip: 'Tes Ping', icon: const Icon(Icons.mail_outline), onPressed: testGoals),
          IconButton(tooltip: 'Petunjuk', icon: const Icon(Icons.lightbulb_outline), onPressed: () => showDialog(context: context, builder: (_) => AlertDialog(
              backgroundColor: kCard, surfaceTintColor: Colors.transparent, title: Text(c.title),
              content: Text('${c.desc}\n\nPetunjuk: ${c.hint}'),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))]))),
          IconButton(tooltip: 'Keluar challenge', icon: const Icon(Icons.close), onPressed: () => setState(() => chal = null)),
        ])));
  }

  // ===================== TOOLBAR MENGAMBANG =====================
  /// Dialog ukuran toolbar mengambang (slider) + reset posisi.
  void toolbarSettings() => showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (_, ss) => AlertDialog(
          backgroundColor: kCard, surfaceTintColor: Colors.transparent, title: const Text('Toolbar mengambang'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ukuran: ${((tbScale ?? tbAuto) * 100).round()}%'),
            Slider(value: (tbScale ?? tbAuto).clamp(0.6, 1.5).toDouble(), min: 0.6, max: 1.5, divisions: 18, onChanged: (v) { setState(() => tbScale = v); ss(() {}); }),
            const Text('Seret toolbar untuk memindahkan, atau cubit dengan 2 jari untuk mengubah ukuran.', style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () { setState(() { tbPos = null; tbScale = null; }); ss(() {}); }, child: const Text('Reset')),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ])));

  /// Toolbar alat yang bisa digeser (drag) dan di-resize (cubit 2 jari / slider di tombol pengaturan).
  Widget toolbar(Map<Tool, IconData> tools) => GestureDetector(
        onScaleStart: (_) => tbBase = tbScale ?? tbAuto,
        onScaleUpdate: (d) => setState(() {
          tbPos = (tbPos ?? tbDef) + d.focalPointDelta;
          if (d.pointerCount > 1) tbScale = (tbBase * d.scale).clamp(0.6, 1.5).toDouble();
        }),
        child: Container(
            decoration: BoxDecoration(color: kCard.withAlpha(235), borderRadius: BorderRadius.circular(14), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.drag_indicator, color: kFg2, size: 20)),
              for (final e in tools.entries)
                IconButton(tooltip: e.key.name, color: tool == e.key ? kAcc : kFg2, icon: Icon(e.value), onPressed: () => setState(() { tool = e.key; first = null; })),
              Container(width: 1, height: 24, color: kFg2),
              IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: undoSt.isEmpty ? null : undo),
              IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: redoSt.isEmpty ? null : redo),
              IconButton(tooltip: 'Ukuran toolbar', icon: const Icon(Icons.tune), onPressed: toolbarSettings),
            ])));

  /// Area canvas: InteractiveViewer + toolbar mengambang + panel pause paket + hint. Dipakai portrait maupun landscape.
  Widget canvasArea(BoxConstraints box, Map<Tool, IconData> tools) {
    const tbW = 480.0; // perkiraan lebar toolbar pada skala 100%
    tbAuto = math.min(1.0, (box.maxWidth - 16) / tbW);
    final sc = tbScale ?? tbAuto;
    tbDef = Offset(math.max(8.0, (box.maxWidth - tbW * sc) / 2), 8);
    final p = tbPos ?? tbDef;
    final pos = Offset(p.dx.clamp(0.0, math.max(0.0, box.maxWidth - 80 * sc)).toDouble(), p.dy.clamp(0.0, math.max(0.0, box.maxHeight - 56 * sc)).toDouble());
    return Stack(children: [
      InteractiveViewer(
        transformationController: ctrl, constrained: false, minScale: .2, maxScale: 3, panEnabled: tool == Tool.hand, boundaryMargin: const EdgeInsets.all(600),
        child: SizedBox(width: 6000, height: 6000, child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (u) {
            if (hitPacket(u.localPosition)) { inspect(); return; } // tap paket = Packet Inspector
            if (tool == Tool.note) addNote(u.localPosition);
            if (tool == Tool.delete && eraseCable) eraseLinkAt(u.localPosition);
          },
          child: Stack(children: [
            Positioned.fill(child: AnimatedBuilder(animation: an, builder: (_, __) => CustomPaint(painter: Pt(devs, links, run, an.value)))),
            for (final n in notes) noteW(n),
            for (final d in devs) devW(d),
          ]),
        )),
      ),
      Positioned(left: pos.dx, top: pos.dy, child: Transform.scale(scale: sc, alignment: Alignment.topLeft, child: toolbar(tools))),
      if (run != null)
        Positioned(bottom: 98, left: 0, right: 0, child: Center(child: AnimatedBuilder(animation: an, builder: (_, __) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: kCard.withAlpha(240), borderRadius: BorderRadius.circular(14)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: an.isAnimating ? 'Pause' : 'Lanjut', icon: Icon(an.isAnimating ? Icons.pause : Icons.play_arrow), onPressed: togglePause),
              Text(run!.phases[math.min((an.value * run!.phases.length).floor(), run!.phases.length - 1)], style: TextStyle(color: kAcc, fontWeight: FontWeight.bold)),
              TextButton.icon(onPressed: inspect, icon: const Icon(Icons.search, size: 18), label: const Text('Inspeksi Paket')),
            ]))))),
      if (tool == Tool.delete)
        Positioned(bottom: 44, left: 0, right: 0, child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: kCard.withAlpha(235), borderRadius: BorderRadius.circular(14)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ChoiceChip(label: const Text('Hapus Perangkat'), selected: !eraseCable, selectedColor: kAcc.withAlpha(90), onSelected: (_) => setState(() => eraseCable = false)),
              const SizedBox(width: 8),
              ChoiceChip(label: const Text('Hapus Kabel Saja'), selected: eraseCable, selectedColor: kAcc.withAlpha(90), onSelected: (_) => setState(() => eraseCable = true)),
            ])))),
      Positioned(bottom: 8, left: 0, right: 0, child: Center(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: kCard.withAlpha(220), borderRadius: BorderRadius.circular(20)),
          child: Text(hint(), style: const TextStyle(fontSize: 12), textAlign: TextAlign.center)))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    const tools = {Tool.select: Icons.near_me, Tool.hand: Icons.pan_tool, Tool.delete: Icons.delete, Tool.inspect: Icons.search, Tool.note: Icons.sticky_note_2, Tool.ping: Icons.mail_outline};
    // AUTO-ROTATE: landscape = menu di kiri, portrait = menu di bawah. State canvas (zoom, perangkat, toolbar) tidak berubah.
    final land = MediaQuery.of(context).orientation == Orientation.landscape;
    Widget nav(IconData i, String t, VoidCallback f, {bool on = false}) => SizedBox(width: 66, child: InkWell(
        onTap: f, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(i, color: on ? kAcc : kFg2), Text(t, style: TextStyle(fontSize: 11, color: on ? kAcc : kFg2)),
        ]))));
    final navItems = [
      nav(Icons.add_box, 'Tambah', addSheet),
      nav(Icons.cable, 'Kabel', cableSheet, on: tool == Tool.cable),
      nav(Icons.delete, 'Hapus', () => setState(() { tool = Tool.delete; first = null; }), on: tool == Tool.delete),
      nav(Icons.play_arrow, 'Play', play),
      nav(Icons.save, 'Save', save),
      nav(Icons.folder_copy, 'Berkas', files),
      nav(Icons.dashboard_customize, 'Template', templates),
      nav(Icons.emoji_events, 'Challenge', challenges, on: chal != null),
    ];
    final canvas = Expanded(child: LayoutBuilder(builder: (_, box) => canvasArea(box, tools)));
    final rail = land
        ? Container(width: 68, color: kCard, child: ListView(children: navItems))
        : Container(height: 62, color: kCard, child: ListView(scrollDirection: Axis.horizontal, children: navItems));
    return Scaffold(
      appBar: AppBar(toolbarHeight: 44, backgroundColor: kBg, title: Text('Reyz Tracer Simulation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: land ? 18 : 15)), actions: [
        IconButton(icon: const Icon(Icons.settings), tooltip: 'Pengaturan', onPressed: settings),
        IconButton(icon: const Icon(Icons.folder_open), tooltip: 'Projek & Lab', onPressed: projects),
        IconButton(icon: const Icon(Icons.calculate), tooltip: 'Kalkulator Subnet', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalcPage()))),
        IconButton(icon: const Icon(Icons.menu_book), tooltip: 'Panduan', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GuidePage()))),
      ]),
      body: SafeArea(top: false, child: Column(children: [
        if (chal != null) challengeBar(),
        Expanded(child: land
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [rail, canvas])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [canvas, rail])),
      ])),
    );
  }
}

/// Gambar teks di tengah titik c (dipakai saat export gambar).
void txt(Canvas cv, String s, Offset c, TextStyle st) {
  final tp = TextPainter(text: TextSpan(text: s, style: st), textDirection: TextDirection.ltr)..layout();
  tp.paint(cv, c - Offset(tp.width / 2, tp.height / 2));
}

/// Garis putus-putus.
void dash(Canvas c, Path p, Paint pt) {
  for (final m in p.computeMetrics()) {
    for (double d = 0; d < m.length; d += 14) c.drawPath(m.extractPath(d, d + 8), pt);
  }
}

/// Painter canvas: grid titik, kabel, titik ijo, dan paket biru.
class Pt extends CustomPainter {
  final List<Dev> devs; final List<Link> links; final PR? run; final double t;
  Pt(this.devs, this.links, this.run, this.t);
  @override
  void paint(Canvas cv, Size sz) {
    final dots = <Offset>[];
    for (double x = 0; x < sz.width; x += 60) for (double y = 0; y < sz.height; y += 60) dots.add(Offset(x, y));
    if (showGrid.value) cv.drawPoints(ui.PointMode.points, dots, Paint()..color = kFg.withAlpha(30)..strokeWidth = 2..strokeCap = StrokeCap.round);
    final mp = {for (final d in devs) d.id: d};
    for (final d in devs.where((x) => x.wifi)) { // HEATMAP jangkauan Wi-Fi: hijau (kuat) -> kuning -> oranye -> merah (lemah)
      final c = d.pos + _o;
      cv.drawCircle(c, d.range, Paint()..shader = ui.Gradient.radial(c, d.range, [Colors.greenAccent.withAlpha(120), Colors.yellowAccent.withAlpha(70), Colors.orangeAccent.withAlpha(35), Colors.redAccent.withAlpha(0)], [0.0, 0.45, 0.8, 1.0]));
      cv.drawCircle(c, d.range, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = Colors.greenAccent.withAlpha(120));
    }
    for (final l in links) {
      final a = mp[l.a]!.pos + _o, b = mp[l.b]!.pos + _o;
      final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5;
      // kabel hijau = kedua ujung sudah terkonfigurasi, merah = ada yang belum
      final lup = linkUp(l, mp[l.a]!, mp[l.b]!), ok = lup && cfg(mp[l.a]!) && cfg(mp[l.b]!); // wireless di luar radius = putus
      final halo = Paint()..style = PaintingStyle.stroke..strokeWidth = 9..strokeCap = StrokeCap.round..color = (ok ? Colors.greenAccent : Colors.redAccent).withAlpha(120);
      if (l.c == 4) {
        final v0 = b - a, m0 = (a + b) / 2;
        final double l0 = v0.distance == 0 ? 1.0 : v0.distance;
        final n0 = Offset(-v0.dy, v0.dx) / l0 * 40;
        cv.drawPath(Path()..moveTo(a.dx, a.dy)..quadraticBezierTo(m0.dx + n0.dx, m0.dy + n0.dy, b.dx, b.dy), halo);
      } else {
        cv.drawLine(a, b, halo);
      }
      switch (l.c) {
        case 0:
          cv.drawLine(a, b, p..color = Colors.black..strokeWidth = 5);
          cv.drawLine(a, b, Paint()..color = Colors.white54..strokeWidth = 1.5);
        case 1:
          dash(cv, Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy), p..color = Colors.redAccent);
        case 2:
          cv.drawLine(a, b, p..color = Colors.amber);
        case 3:
          cv.drawLine(a, b, p..color = kAcc);
        default:
          final mid = (a + b) / 2, v = b - a;
          final double len = v.distance == 0 ? 1.0 : v.distance;
          final n = Offset(-v.dy, v.dx) / len * 40;
          dash(cv, Path()..moveTo(a.dx, a.dy)..quadraticBezierTo(mid.dx + n.dx, mid.dy + n.dy, b.dx, b.dy), p..color = lup ? Colors.cyanAccent : Colors.grey.withAlpha(120));
          if (!lup) { // tanda silang merah = Wi-Fi terputus
            final x = mid + n / 2, xp = Paint()..color = Colors.redAccent..strokeWidth = 3..strokeCap = StrokeCap.round;
            cv.drawLine(x + const Offset(-7, -7), x + const Offset(7, 7), xp);
            cv.drawLine(x + const Offset(7, -7), x + const Offset(-7, 7), xp);
          }
      }
      for (final e in [(a, b, lup && cfg(mp[l.a]!)), (b, a, lup && cfg(mp[l.b]!))]) { // titik ujung: hijau = terkonfigurasi, merah = belum
        final u = e.$2 - e.$1;
        final double ul = u.distance == 0 ? 1.0 : u.distance;
        cv.drawCircle(e.$1 + u / ul * 34, 5, Paint()..color = e.$3 ? Colors.greenAccent : Colors.redAccent);
      }
    }
    final at = pktAt(run, mp, t);
    if (at != null) { // paket jalan: ARP oranye, ICMP biru, DHCP ungu
      final ph = run!.phases[at.ph];
      final Color c = ph == 'ARP' ? Colors.orangeAccent : (ph == 'DHCP' ? Colors.purpleAccent : const Color(0xFF3DA5FF));
      cv.drawCircle(at.p, 13, Paint()..color = c.withAlpha(90)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      cv.drawCircle(at.p, 6, Paint()..color = c);
      cv.drawCircle(at.p, 10, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = kFg);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter o) => true;
}

/// Halaman setting device (layar penuh supaya tidak ketutup keyboard): tab Config, DHCP (khusus Server), dan Command Prompt / CLI dengan kolom input ala chat.
class DevDialog extends StatefulWidget {
  final Dev d; final SimState s; final VoidCallback refresh;
  const DevDialog(this.d, this.s, this.refresh, {super.key});
  @override
  State<DevDialog> createState() => _DevDlgState();
}

class _DevDlgState extends State<DevDialog> {
  Dev get d => widget.d;
  late final n = TextEditingController(text: d.name), ip = TextEditingController(text: d.ip),
      mk = TextEditingController(text: d.mask), gw = TextEditingController(text: d.gw), cmd = TextEditingController(), dns = TextEditingController(text: d.dns),
      pool = TextEditingController(text: d.pool), psz = TextEditingController(text: '${d.poolSize}'), dgw = TextEditingController(text: d.dgw);
  final sc = ScrollController(), fn = FocusNode();
  String msg = '', before = '';

  @override
  void dispose() {
    widget.s.commit(before); // masuk riwayat undo kalau ada perubahan
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    before = widget.s.snap();
    if (d.log.isEmpty) d.log.add(d.t == T.router ? 'Reyz Router CLI\nKetik: enable, conf t, interface g0/0, ip address <ip> <mask>, no shutdown, ip route <net> <mask> <next-hop>, do show ip route\n' : 'Reyz Command Prompt\nKetik: ping <ip>, ipconfig, ipconfig /renew, cls\n');
  }

  /// Simpan isian Config langsung saat diketik.
  void save() {
    d.name = n.text; d.pool = pool.text.trim(); d.poolSize = int.tryParse(psz.text.trim()) ?? d.poolSize; d.dgw = dgw.text.trim();
    if (!d.useDhcp) { d.ip = ip.text.trim(); d.mask = mk.text.trim(); d.gw = gw.text.trim(); d.dns = dns.text.trim(); }
    widget.refresh();
    if (mounted) setState(() {});
  }

  /// Salin nilai IP dari device ke kolom teks.
  final ic = <String, List<TextEditingController>>{}; // kolom IP/mask per interface router
  void sync() {
    ip.text = d.ip; mk.text = d.mask; gw.text = d.gw; dns.text = d.dns;
    d.ifs.forEach((k, f) { final c = ic[k]; if (c != null) { c[0].text = f.ip; c[1].text = f.mask; } });
  }

  /// Nyalakan / matikan DHCP pada client.
  void applyDhcp(bool v) {
    setState(() {
      d.useDhcp = v;
      if (v) {
        d.ip = ''; d.gw = '';
        final r = widget.s.dhcpRequest(d);
        msg = r == null ? 'DHCP gagal: tidak ada server DHCP aktif yang terhubung' : 'DHCP berhasil, IP: $r';
      } else {
        msg = '';
      }
      sync();
    });
    widget.refresh();
  }

  /// Kirim perintah (tombol kirim / enter), hasilnya tampil di layar terminal.
  void send() {
    final v = cmd.text;
    if (v.trim().isEmpty) return;
    setState(() {
      d.log.add('${widget.s.prompt(d)}$v');
      final o = widget.s.cli(d, v);
      if (o == '\u0000') d.log.clear(); else if (o.isNotEmpty) d.log.add(o);
      sync();
    });
    cmd.clear(); fn.requestFocus(); widget.refresh();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (sc.hasClients) sc.jumpTo(sc.position.maxScrollExtent); });
  }

  /// Kolom isian dengan pesan error merah kalau kosong / salah format.
  Widget field(TextEditingController c, String l, {bool en = true, bool num = true, String? err, void Function(String)? onCh}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
          controller: c, enabled: en, onChanged: (v) { onCh?.call(v); save(); }, keyboardType: num ? TextInputType.number : null,
          decoration: InputDecoration(labelText: l, isDense: true, errorText: err, border: const OutlineInputBorder())));

  /// Kolom berdampingan kalau layar lebar (landscape), menumpuk kalau sempit (portrait).
  Widget formRow(List<Widget> f) => LayoutBuilder(builder: (_, c) => c.maxWidth > 220.0 * f.length
      ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < f.length; i++) Expanded(child: Padding(padding: EdgeInsets.only(right: i < f.length - 1 ? 8.0 : 0.0), child: f[i]))])
      : Column(children: f));

  /// FORM IP MANUAL (wajib) untuk end device & server: IP Address, Subnet Mask, Default Gateway, DNS.
  List<Widget> ipForm() => [
        SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('DHCP (IP otomatis)'), value: d.useDhcp, onChanged: applyDhcp),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(msg, style: TextStyle(color: msg.startsWith('DHCP gagal') ? Colors.red : Colors.green))),
        formRow([
          field(ip, 'IP Address', en: !d.useDhcp, err: d.useDhcp ? null : ipErr(ip.text)),
          field(mk, 'Subnet Mask', en: !d.useDhcp, err: d.useDhcp ? null : maskErr(mk.text)),
        ]),
        formRow([
          field(gw, 'Default Gateway', en: !d.useDhcp, err: d.useDhcp ? null : ipErr(gw.text)),
          field(dns, 'DNS Server', en: !d.useDhcp, err: d.useDhcp ? null : ipErr(dns.text)),
        ]),
      ];

  /// FORM ROUTER: default gateway (next-hop upstream, opsional), DNS, lalu IP/mask/status tiap interface (IP & mask wajib).
  List<Widget> routerForm() => [
        formRow([
          field(gw, 'Default Gateway (next-hop, opsional)', err: gw.text.trim().isEmpty ? null : ipErr(gw.text)),
          field(dns, 'DNS Server (opsional)', err: dns.text.trim().isEmpty ? null : ipErr(dns.text)),
        ]),
        for (final e in d.ifs.entries) ...ifaceForm(e.key, e.value),
      ];

  /// Satu interface router: IP, Subnet Mask, dan switch Up/Down.
  List<Widget> ifaceForm(String k, Iface f) {
    final c = ic.putIfAbsent(k, () => [TextEditingController(text: f.ip), TextEditingController(text: f.mask)]);
    return [
      Padding(padding: const EdgeInsets.only(top: 4, bottom: 6), child: Row(children: [
        Expanded(child: Text('GigabitEthernet${k.substring(1)}', style: TextStyle(color: kAcc, fontWeight: FontWeight.bold))),
        Text(f.up ? 'Up' : 'Down'),
        Switch(value: f.up, onChanged: (v) { setState(() => f.up = v); widget.refresh(); }),
      ])),
      formRow([
        field(c[0], 'IP Address', err: ipErr(c[0].text), onCh: (v) => f.ip = v.trim()),
        field(c[1], 'Subnet Mask', err: maskErr(c[1].text), onCh: (v) => f.mask = v.trim()),
      ]),
    ];
  }

  /// INTERFACE SWITCH: 24 port FastEthernet (Fa0/1 - Fa0/24) dengan status Up/Down dan VLAN manual. Tap baris untuk ubah VLAN.
  List<Widget> switchPorts() {
    widget.s.fixPorts();
    return [
      Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: Text('Interface FastEthernet0/1 - 0/24 (tap baris = ubah VLAN)', style: TextStyle(color: kAcc, fontWeight: FontWeight.bold))),
      for (var i = 0; i < d.ports.length; i++)
        Builder(builder: (_) {
          final pt = d.ports[i];
          final lk = widget.s.links.where((l) => widget.s.portOf(l, d.id) == i + 1).firstOrNull;
          final peer = lk == null ? null : widget.s.byId(lk.a == d.id ? lk.b : lk.a).name;
          return ListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.circle, size: 12, color: !pt.up ? Colors.red : (peer == null ? Colors.grey : Colors.green)),
              title: Text('Fa0/${i + 1}   ${peer ?? '(kosong)'}'),
              subtitle: Text('VLAN ${pt.vlan}  -  ${pt.up ? 'Up' : 'Down'}'),
              onTap: () async {
                final v = await widget.s.ask('VLAN Fa0/${i + 1} (1-4094)', '${pt.vlan}');
                final nv = int.tryParse(v ?? '');
                if (nv != null && nv >= 1 && nv <= 4094) { setState(() => pt.vlan = nv); widget.refresh(); }
              },
              trailing: Switch(value: pt.up, onChanged: (v) { setState(() => pt.up = v); widget.refresh(); }));
        }),
    ];
  }

  /// Pengaturan Wi-Fi (Access Point / Router): radius sinyal untuk heatmap.
  List<Widget> wifiBlock() => [
        const Divider(),
        if (d.t == T.router) SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('Wi-Fi (radiasi sinyal)'), value: d.wifi, onChanged: (v) { setState(() => d.wifi = v); widget.refresh(); }),
        if (d.wifi) ...[
          Text('Radius sinyal: ${d.range.round()} px (heatmap tampil di canvas)'),
          Slider(value: d.range.clamp(60.0, 500.0).toDouble(), min: 60, max: 500, divisions: 44, onChanged: (x) { setState(() => d.range = x); widget.refresh(); }),
          const Text('Sambungkan HP/Laptop/Tablet dengan Kabel Wireless. Di luar lingkaran = Wi-Fi terputus.', style: TextStyle(fontSize: 12)),
        ],
      ];

  Widget config() => ListView(padding: const EdgeInsets.all(12), children: [
        field(n, 'Nama Device', num: false),
        if (!netDev(d.t) && d.t != T.router) ...ipForm(),
        if (d.t == T.router) ...routerForm(),
        if (d.t == T.ap || d.t == T.router) ...wifiBlock(),
        if (d.t == T.sw) ...switchPorts(),
        if (!passive(d.t)) Padding(padding: const EdgeInsets.only(top: 8), child: Text(cfg(d) ? 'Status: terkonfigurasi (kabel hijau)' : 'Status: belum terkonfigurasi (kabel merah)', style: TextStyle(color: cfg(d) ? Colors.green : Colors.red))),
        if (passive(d.t) && d.t != T.sw && d.t != T.ap) const Text('Device ini tidak butuh IP. Cukup sambungkan kabel.'),
      ]);

  Widget dhcpTab() => ListView(padding: const EdgeInsets.all(12), children: [
        SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('Layanan DHCP'), subtitle: Text(d.dhcp ? 'Aktif' : 'Mati'), value: d.dhcp, onChanged: (v) { setState(() => d.dhcp = v); widget.refresh(); }),
        formRow([field(pool, 'IP awal pool'), field(psz, 'Jumlah alamat'), field(dgw, 'Default Gateway')]),
        Text('Subnet mask pool mengikuti mask server (${d.mask}). Server harus punya IP, dan client harus satu jaringan (tersambung lewat switch/hub/AP).'),
      ]);

  /// Terminal + kolom input ala chat di bagian bawah (naik di atas keyboard).
  Widget term() => Column(children: [
        Expanded(child: Container(
            color: Colors.black, width: double.infinity, padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(controller: sc, child: Text(d.log.join('\n'), style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12))))),
        Container(
            color: kCard, padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(children: [
              Text(widget.s.prompt(d), style: TextStyle(color: kAcc, fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(width: 6),
              Expanded(child: TextField(
                  controller: cmd, focusNode: fn, autocorrect: false, enableSuggestions: false, textInputAction: TextInputAction.send, onSubmitted: (_) => send(),
                  decoration: InputDecoration(
                      isDense: true, hintText: 'Ketik perintah...', filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)))),
              IconButton(icon: const Icon(Icons.send), color: kAcc, onPressed: send),
            ])),
      ]);

  @override
  Widget build(BuildContext context) {
    final cli = !passive(d.t), dh = d.t == T.server;
    final tabs = ['Config', if (dh) 'DHCP', if (cli) d.t == T.router ? 'CLI' : 'Command Prompt'];
    return DefaultTabController(length: tabs.length, child: Scaffold(
      appBar: AppBar(toolbarHeight: 40, backgroundColor: kBg, title: Text(d.name, style: const TextStyle(fontSize: 16)), bottom: TabBar(tabs: [for (final t in tabs) Tab(text: t, height: 34)])),
      body: TabBarView(children: [config(), if (dh) dhcpTab(), if (cli) term()]),
    ));
  }
}

/// Halaman kalkulator subnet.
class CalcPage extends StatefulWidget {
  const CalcPage({super.key});
  @override
  State<CalcPage> createState() => _CalcState();
}

class _CalcState extends State<CalcPage> {
  final c = TextEditingController(text: '192.168.1.0/24');
  String out = '';

  /// Hitung Network, Broadcast, jumlah host, range IP.
  void hitung() {
    final x = c.text.trim().split('/');
    final ip = ipn(x[0]), n = x.length == 2 ? int.tryParse(x[1]) : null;
    if (ip == null || n == null || n < 0 || n > 32) { setState(() => out = 'Format salah. Contoh: 192.168.1.0/24'); return; }
    final mk = (0xFFFFFFFF << (32 - n)) & 0xFFFFFFFF, net = ip & mk, bc = net | (~mk & 0xFFFFFFFF);
    final host = n >= 31 ? (n == 32 ? 1 : 2) : (1 << (32 - n)) - 2;
    setState(() => out = 'Network     : ${ips(net)}\nSubnet Mask : ${ips(mk)}\nBroadcast   : ${ips(bc)}\nJumlah Host : $host\nRange IP    : ${ips(n >= 31 ? net : net + 1)} - ${ips(n >= 31 ? bc : bc - 1)}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Kalkulator Subnet'), backgroundColor: kBg),
      body: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: c, decoration: const InputDecoration(labelText: 'IP/Prefix', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: hitung, child: const Text('Hitung'))),
        const SizedBox(height: 16),
        SelectableText(out, style: TextStyle(fontFamily: 'monospace', fontSize: 14, color: kAcc)),
      ])));
}

/// Halaman panduan singkat.
class GuidePage extends StatelessWidget {
  const GuidePage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Panduan'), backgroundColor: kBg),
      body: const SingleChildScrollView(padding: EdgeInsets.all(16), child: Text(
          'CARA SETTING IP\n\n'
          '1. Tap Tambah, pilih device (PC, Switch, Router, dll).\n'
          '2. Tap Kabel, pilih jenis kabel, lalu tap 2 device. Titik hijau = tersambung.\n'
          '3. Tap PC, isi IP Address, Subnet Mask, Gateway di tab Config.\n'
          '   Contoh PC1: 192.168.1.1 / 255.255.255.0\n'
          '4. Buka tab Command Prompt, ketik: ping 192.168.1.2\n'
          '5. Tekan Play untuk lihat animasi paket biru.\n\n'
          'AGAR BEDA JARINGAN BISA PING\n\n'
          'PC1 192.168.1.2 gateway 192.168.1.1, PC2 192.168.2.2 gateway 192.168.2.1. Lalu di router:\n'
          'enable\nconf t\ninterface g0/0\nip address 192.168.1.1 255.255.255.0\nno shutdown\nexit\n'
          'interface g0/1\nip address 192.168.2.1 255.255.255.0\nno shutdown\nend\ndo show ip route\n\n'
          'FITUR BARU v1.4\n\n'
          'Rotasi layar: aplikasi mengikuti posisi HP (portrait/landscape), isi canvas tetap. Toolbar atas bisa digeser dan dicubit untuk mengubah ukuran (ikon tune untuk slider). '
          'Switch: Config menampilkan 24 port (Fa0/1-0/24) dengan Up/Down dan VLAN manual; dua perangkat hanya bisa saling ping kalau port-nya Up dan VLAN-nya sama. '
          'Access Point / Router Wi-Fi memancarkan heatmap sinyal; HP/Laptop yang disambung Kabel Wireless putus kalau digeser keluar lingkaran. '
          'Saat paket berjalan, tekan Pause lalu Inspeksi Paket (atau tap titik paketnya) untuk melihat MAC, IP, dan protokol (ARP/ICMP/DHCP). '
          'Menu Challenge berisi 6 soal jaringan bermasalah dengan indikator ping otomatis.\n\n'
          'UNDO / REDO & HAPUS\n\n'
          'Tombol panah di toolbar atas canvas: Undo dan Redo (tambah/hapus perangkat, kabel, geser, rename, ubah IP). Tool Hapus punya 2 mode: Hapus Perangkat (kabel ikut terhapus) dan Hapus Kabel Saja (tap garis kabelnya, perangkat tetap ada).\n\n'
          'BERKAS & TEMPLATE\n\n'
          'Menu Berkas (kiri): Export projek jadi file .rts, Import file .rts, dan Export canvas ke gambar PNG. Menu Template: Basic LAN, Router to Router, Smart Home IoT, dan lab latihan.\n\n'
          'ROUTING STATIS\n\n'
          'Di CLI router (mode conf t): ip route 192.168.2.0 255.255.255.0 10.0.0.2 (jaringan, mask, next-hop). Lihat hasilnya dengan do show ip route (baris S = static). Ping lintas router butuh rute di kedua arah.\n\n'
          'INDIKATOR KABEL\n\n'
          'Kabel bercahaya HIJAU kalau kedua ujungnya sudah terkonfigurasi, MERAH kalau ada yang belum (PC belum diisi IP, router belum ada interface yang no shutdown). Switch, Hub, AP, dan IoT tidak perlu konfigurasi.\n\n'
          'DHCP\n\n'
          'Server > tab DHCP: aktifkan layanan, isi IP awal pool, jumlah alamat, gateway. Di PC > Config nyalakan DHCP (atau ketik ipconfig /renew di Command Prompt). Client dan server harus satu jaringan lewat switch/hub.\n\n'
          'TEMA\n\n'
          'Ikon gerigi (Pengaturan): pilih Biru Dongker, Hitam, atau Putih.\n\n'
          'SIMULASI IoT\n\n'
          'Menu Tambah > tab IoT & Sensor: Saklar, Sensor Gerak, Lampu, Alarm, IoT Gateway. Sambungkan pakai Kabel (sensor ke lampu langsung, atau lewat gateway). '
          'Tap Saklar / Sensor Gerak untuk ON/OFF, Lampu & Alarm ikut berubah otomatis. Tap Lampu/Alarm (atau tool Inspect) untuk buka panel, lalu tekan Update.\n\n'
          'TIPS\n\n'
          'Tekan lama device untuk ganti nama / hapus. Tool Hand untuk geser canvas, cubit 2 jari untuk zoom. '
          'Tool Ping (amplop) kirim PDU dari device asal ke tujuan.',
          style: TextStyle(height: 1.5))));
}

/// Panel kontrol IoT: ubah nama, status sensor, dan koneksi. Tombol "Update" menerapkan perubahan.
class IotDialog extends StatefulWidget {
  final Dev d; final SimState s; final VoidCallback refresh;
  const IotDialog(this.d, this.s, this.refresh, {super.key});
  @override
  State<IotDialog> createState() => _IotState();
}

class _IotState extends State<IotDialog> {
  Dev get d => widget.d;
  late final n = TextEditingController(text: d.name), ip = TextEditingController(text: d.ip), mk = TextEditingController(text: d.mask),
      gw = TextEditingController(text: d.gw), dns = TextEditingController(text: d.dns);
  late bool v = d.on;
  late double tv = d.temp, th = d.thr;

  /// Terapkan perubahan (nama + status sensor), lalu hitung ulang semua Lampu/Alarm.
  void update() {
    widget.s.rec();
    if (n.text.trim().isNotEmpty) d.name = n.text.trim();
    d.ip = ip.text.trim(); d.mask = mk.text.trim(); d.gw = gw.text.trim(); d.dns = dns.text.trim();
    if (d.t == T.tempSensor) { d.temp = tv; d.thr = th; d.on = tv >= th; } else if (sensor(d.t)) d.on = v;
    widget.s.propagate();
    widget.refresh();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final conns = widget.s.links.where((l) => l.a == d.id || l.b == d.id).toList();
    return AlertDialog(
      backgroundColor: kCard, surfaceTintColor: Colors.transparent,
      title: Text('Panel ${tInfo[d.t]!.$1}'),
      content: SizedBox(width: 380, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Nama Device', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        if (d.t == T.tempSensor) ...[
          Text('Suhu terbaca: ${tv.round()}°C'),
          Slider(value: tv, min: 0, max: 60, divisions: 60, label: '${tv.round()}°C', onChanged: (x) => setState(() => tv = x)),
          Text('Aktif jika suhu >= ${th.round()}°C'),
          Slider(value: th, min: 0, max: 60, divisions: 60, label: '${th.round()}°C', onChanged: (x) => setState(() => th = x)),
        ] else if (sensor(d.t)) SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(d.t == T.motion ? 'Gerakan terdeteksi' : 'Saklar'), subtitle: Text(v ? 'ON' : 'OFF'), value: v, onChanged: (x) => setState(() => v = x)),
        if (actuator(d.t)) Text('Status: ${d.on ? 'ON (menyala)' : 'OFF (mati)'}\nOtomatis mengikuti sensor yang terhubung.'),
        if (d.t == T.iotGw) const Text('Gateway meneruskan sinyal sensor ke Lampu/Alarm.'),
        const SizedBox(height: 10),
        Text('Pengaturan IP manual (opsional, bisa di-ping dari PC)', style: TextStyle(color: kAcc, fontSize: 12)),
        for (final f in [(ip, 'IP Address'), (mk, 'Subnet Mask'), (gw, 'Default Gateway'), (dns, 'DNS Server')])
          Padding(padding: const EdgeInsets.only(top: 8), child: TextField(controller: f.$1, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: f.$2, isDense: true, border: const OutlineInputBorder()))),
        const SizedBox(height: 10),
        Text('Koneksi:', style: TextStyle(color: kAcc)),
        if (conns.isEmpty) const Text('Belum ada kabel. Pakai tombol Kabel.'),
        for (final l in conns)
          ListTile(
              dense: true, contentPadding: EdgeInsets.zero, title: Text(widget.s.byId(l.a == d.id ? l.b : l.a).name),
              trailing: IconButton(icon: const Icon(Icons.link_off, color: Colors.redAccent), tooltip: 'Putus kabel', onPressed: () {
                widget.s.rec(); widget.s.links.remove(l); widget.s.propagate(); widget.refresh(); setState(() {});
              })),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: update, child: const Text('Update')),
      ],
    );
  }
}
