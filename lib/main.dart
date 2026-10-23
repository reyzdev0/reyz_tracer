// ignore_for_file: curly_braces_in_flow_control_structures
// Reyz Tracer Simulation - simulasi jaringan ala Packet Tracer (versi HP)
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kBg = Color(0xFF0A1931), kAcc = Color(0xFF00A8FF), kCard = Color(0xFF12284A);
const _o = Offset(36, 30); // titik tengah icon device terhadap posisinya

enum T { router, sw, hub, ap, wlc, pc, laptop, server, phone, printer, ipPhone }
enum Tool { select, hand, delete, inspect, note, ping, cable }

const tInfo = {
  T.router: ('Router', Icons.router), T.sw: ('Switch', Icons.lan), T.hub: ('Hub', Icons.hub),
  T.ap: ('AccessPoint', Icons.wifi_tethering), T.wlc: ('WLC', Icons.settings_input_antenna),
  T.pc: ('PC', Icons.desktop_windows), T.laptop: ('Laptop', Icons.laptop), T.server: ('Server', Icons.dns),
  T.phone: ('Smartphone', Icons.smartphone), T.printer: ('Printer', Icons.print), T.ipPhone: ('IPPhone', Icons.phone_in_talk),
};
const cbl = [
  ('Straight', 'Garis hitam lurus', Colors.white70), ('Crossover', 'Merah putus-putus', Colors.redAccent),
  ('Fiber', 'Garis kuning', Colors.amber), ('Console', 'Garis biru', kAcc),
  ('Wireless', 'Putus-putus melengkung (ke AP)', Colors.cyanAccent),
];

bool netDev(T t) => t.index <= T.wlc.index; // router, switch, hub, AP, WLC
bool passive(T t) => t.index >= T.sw.index && t.index <= T.wlc.index; // device L2 (meneruskan frame)

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

/// Data satu device di canvas.
class Dev {
  int id; T t; String name; Offset pos;
  String ip = '', mask = '255.255.255.0', gw = '';
  final Map<String, Iface> ifs = {};
  final List<String> log = [];
  int mode = 0; String cur = ''; // mode CLI router: 0 user, 1 priv, 2 config, 3 config-if
  Dev(this.id, this.t, this.name, this.pos) { if (t == T.router) { ifs['g0/0'] = Iface(); ifs['g0/1'] = Iface(); } }
  Map toJ() => {'id': id, 't': t.index, 'n': name, 'x': pos.dx, 'y': pos.dy, 'ip': ip, 'mk': mask, 'gw': gw,
        'ifs': ifs.map((k, v) => MapEntry(k, [v.ip, v.mask, v.up]))};
  static Dev fromJ(Map j) {
    final d = Dev(j['id'], T.values[j['t']], j['n'], Offset(j['x'], j['y']))..ip = j['ip']..mask = j['mk']..gw = j['gw'];
    (j['ifs'] as Map).forEach((k, v) => d.ifs[k] = Iface()..ip = v[0]..mask = v[1]..up = v[2]);
    return d;
  }
}

class Link { int a, b, c; Link(this.a, this.b, this.c); } // c = jenis kabel (0-4)
class Note { Offset pos; String text; Note(this.pos, this.text); }
class PR { bool ok; String msg; List<int> path; PR(this.ok, this.msg, this.path); } // hasil ping

void main() => runApp(const ReyzApp());

class ReyzApp extends StatelessWidget {
  const ReyzApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'Reyz Tracer Simulation', debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
            scaffoldBackgroundColor: kBg, colorScheme: const ColorScheme.dark(primary: kAcc, surface: kCard)),
        home: const Sim());
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

  Dev byId(int id) => devs.firstWhere((d) => d.id == id);

  /// Tambah device baru ke daftar.
  Dev add(T t, Offset p, {String ip = '', String gw = ''}) {
    final n = devs.where((d) => d.t == t).length + 1;
    final d = Dev(nid++, t, '${tInfo[t]!.$1}$n', p)..ip = ip..gw = gw;
    devs.add(d);
    return d;
  }

  /// Tetangga device lewat kabel data (kabel console tidak membawa data).
  List<int> nbrs(int id) => links.where((l) => l.c != 3 && (l.a == id || l.b == id)).map((l) => l.a == id ? l.b : l.a).toList();

  /// Cari jalur Layer 2 dari a ke b, hanya lewat switch/hub/AP.
  List<int>? l2(int a, int b) {
    final prev = <int, int>{a: -1};
    final q = [a];
    while (q.isNotEmpty) {
      final u = q.removeAt(0);
      if (u == b) {
        final r = <int>[];
        for (var x = b; x != -1; x = prev[x]!) r.add(x);
        return r.reversed.toList();
      }
      if (u != a && !passive(byId(u).t)) continue;
      for (final v in nbrs(u)) if (!prev.containsKey(v)) { prev[v] = u; q.add(v); }
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
      if (p == null) return PR(false, 'Gagal! Kabel ${s.name} ke ${d.name} belum tersambung', []);
      return PR(true, 'Berhasil! Ping dari ${s.name} ke ${d.name} Reply', p);
    }
    if (sgw.isEmpty) return PR(false, 'Gagal! Beda jaringan, isi Gateway di ${s.name}', []);
    if (!same(sip, sgw, smk)) return PR(false, 'Gagal! Gateway $sgw beda jaringan dengan ${s.name}', []);
    final r = devs.where((e) => e.t == T.router && e.ifs.values.any((i) => i.ip == sgw && i.up)).firstOrNull;
    if (r == null) return PR(false, 'Gagal! Gateway $sgw tidak ditemukan / interface router belum no shutdown', []);
    final p1 = l2(s.id, r.id);
    if (p1 == null) return PR(false, 'Gagal! ${s.name} belum tersambung ke router gateway', []);
    if (!r.ifs.values.any((i) => i.up && same(i.ip, dst, i.mask))) return PR(false, 'Gagal! Router tidak punya rute ke jaringan $dst, cek IP interface router', []);
    final p2 = l2(r.id, d.id);
    if (p2 == null) return PR(false, 'Gagal! Router belum tersambung ke ${d.name}', []);
    if (d.t != T.router && d.gw.isEmpty) return PR(false, 'Gagal! Gateway ${d.name} kosong, balasan tidak bisa kembali', []);
    return PR(true, 'Berhasil! Ping dari ${s.name} ke ${d.name} Reply (via ${r.name})', [...p1, ...p2.skip(1)]);
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
    return r.isEmpty ? '(Belum ada rute. Atur ip address lalu no shutdown)' : 'Codes: C - connected\n\n${r.join('\n')}';
  }

  /// Menjalankan perintah CLI (PC = Command Prompt, Router = CLI palsu).
  String cli(Dev d, String raw) {
    if (raw.trim().isEmpty) return '';
    var w = raw.trim().toLowerCase().split(RegExp(r'\s+'));
    if (d.t != T.router) {
      if (w[0] == 'ping') return w.length < 2 ? 'Pemakaian: ping <ip>' : pingOut(d, w[1]);
      if (w[0] == 'ipconfig') return 'IPv4 Address. . . . : ${d.ip}\nSubnet Mask . . . . : ${d.mask}\nDefault Gateway . . : ${d.gw}';
      if (w[0] == 'cls') return '\u0000';
      return 'Perintah tidak dikenal. Coba: ping, ipconfig, cls';
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

  /// Jalankan ping + animasi paket biru, lalu tampilkan notifikasi.
  void runPing(PR r) {
    if (!r.ok || r.path.length < 2) { toast(r.ok, r.msg); return; }
    setState(() => run = r);
    an.duration = Duration(milliseconds: 700 * (r.path.length - 1));
    an.forward(from: 0).then((_) {
      if (!mounted) return;
      setState(() => run = null);
      toast(true, r.msg);
    });
  }

  /// Kirim PDU/ping dari device s ke device d.
  void pduTo(Dev s, Dev d) {
    final dip = d.t == T.router ? (d.ifs.values.where((i) => i.ip.isNotEmpty).firstOrNull?.ip ?? '') : d.ip;
    if (dip.isEmpty) { toast(false, 'Gagal! ${d.name} belum punya IP Address'); return; }
    runPing(pingDev(s, dip));
  }

  /// Tombol PLAY: ping otomatis antara 2 end device pertama.
  void play() {
    final e = devs.where((d) => !netDev(d.t)).toList();
    if (e.length < 2) { toast(false, 'Tambah minimal 2 end device dulu'); return; }
    pduTo(e[0], e[1]);
  }

  /// Aksi saat device di-tap, tergantung tool aktif.
  void tap(Dev d) {
    switch (tool) {
      case Tool.delete:
        setState(() { devs.remove(d); links.removeWhere((l) => l.a == d.id || l.b == d.id); run = null; });
      case Tool.cable:
        if (first == null) { setState(() => first = d.id); return; }
        final a = first!;
        setState(() => first = null);
        if (a == d.id) return;
        if (links.any((l) => (l.a == a && l.b == d.id) || (l.a == d.id && l.b == a))) { toast(false, 'Kedua device sudah terhubung'); return; }
        final ap = byId(a).t == T.ap || d.t == T.ap || byId(a).t == T.wlc || d.t == T.wlc;
        if (cable == 4 && !ap) { toast(false, 'Kabel wireless harus ke Access Point'); return; }
        setState(() => links.add(Link(a, d.id, cable)));
      case Tool.ping:
        if (first == null) { setState(() => first = d.id); return; }
        final s = byId(first!);
        setState(() => first = null);
        if (s != d) pduTo(s, d);
      default:
        showDialog(context: context, builder: (_) => DevDialog(d, this, () => setState(() {})));
    }
  }

  Future<String?> ask(String title, String init) {
    final c = TextEditingController(text: init);
    return showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(backgroundColor: kCard, title: Text(title), content: TextField(controller: c, autofocus: true), actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
              FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('OK')),
            ]));
  }

  /// Tambah catatan teks di canvas.
  Future<void> addNote(Offset o) async {
    final t = await ask('Catatan', '');
    if (t != null && t.isNotEmpty) setState(() => notes.add(Note(o, t)));
  }

  /// Tekan lama device: ganti nama / hapus.
  void menu(Dev d) => showModalBottomSheet(
      context: context, backgroundColor: kCard,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(leading: const Icon(Icons.edit), title: const Text('Ganti nama'), onTap: () async {
              Navigator.pop(context);
              final n = await ask('Nama device', d.name);
              if (n != null && n.isNotEmpty) setState(() => d.name = n);
            }),
            ListTile(leading: const Icon(Icons.delete, color: Colors.redAccent), title: const Text('Hapus device'), onTap: () {
              Navigator.pop(context);
              setState(() { devs.remove(d); links.removeWhere((l) => l.a == d.id || l.b == d.id); });
            }),
          ]));

  /// Taruh device baru di tengah layar.
  void spawn(T t) {
    final sz = MediaQuery.of(context).size, k = (devs.length % 4) * 24.0;
    final c = ctrl.toScene(Offset(sz.width / 2, sz.height / 3));
    setState(() => add(t, c + Offset(k, k) - _o));
  }

  Widget grid(List<T> l) => GridView.count(crossAxisCount: 3, children: [
        for (final t in l)
          InkWell(onTap: () { Navigator.pop(context); spawn(t); }, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(tInfo[t]!.$2, color: kAcc, size: 34), const SizedBox(height: 4), Text(tInfo[t]!.$1, style: const TextStyle(fontSize: 12)),
          ])),
      ]);

  /// Toolbox: 2 tab (Network Devices & End Devices).
  void addSheet() => showModalBottomSheet(
      context: context, backgroundColor: kCard,
      builder: (_) => DefaultTabController(length: 2, child: SizedBox(height: 300, child: Column(children: [
            const TabBar(tabs: [Tab(text: 'Network Devices'), Tab(text: 'End Devices')]),
            Expanded(child: TabBarView(children: [grid(T.values.where(netDev).toList()), grid(T.values.where((t) => !netDev(t)).toList())])),
          ]))));

  /// Pilih jenis kabel lalu tap 2 device.
  void cableSheet() => showModalBottomSheet(
      context: context, backgroundColor: kCard,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < cbl.length; i++)
              ListTile(
                  leading: Icon(Icons.timeline, color: cbl[i].$3), title: Text('Kabel ${cbl[i].$1}'), subtitle: Text(cbl[i].$2),
                  onTap: () { Navigator.pop(context); setState(() { cable = i; tool = Tool.cable; first = null; }); }),
          ]));

  Map toJ() => {
        'devs': devs.map((d) => d.toJ()).toList(), 'links': links.map((l) => [l.a, l.b, l.c]).toList(),
        'notes': notes.map((n) => [n.pos.dx, n.pos.dy, n.text]).toList(),
      };

  /// Muat topologi dari JSON.
  void fromJ(Map j) => setState(() {
        devs..clear()..addAll((j['devs'] as List).map((e) => Dev.fromJ(e)));
        links..clear()..addAll((j['links'] as List).map((e) => Link(e[0], e[1], e[2])));
        notes..clear()..addAll((j['notes'] as List).map((e) => Note(Offset(e[0], e[1]), e[2])));
        nid = devs.fold(0, (m, d) => d.id > m ? d.id : m) + 1;
        first = null; run = null;
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
    fromJ({'devs': [], 'links': [], 'notes': []});
    final a = add(T.pc, const Offset(120, 250), ip: '192.168.1.1'), s = add(T.sw, const Offset(360, 250));
    final b = add(T.pc, const Offset(600, 250), ip: '192.168.1.2');
    setState(() => links..add(Link(a.id, s.id, 0))..add(Link(s.id, b.id, 0)));
  }

  /// Lab 2: 2 jaringan + 1 Router (router belum dikonfigurasi, latihan CLI).
  void lab2() {
    fromJ({'devs': [], 'links': [], 'notes': []});
    final a = add(T.pc, const Offset(80, 300), ip: '192.168.1.2', gw: '192.168.1.1');
    final s1 = add(T.sw, const Offset(260, 300)), r = add(T.router, const Offset(450, 300)), s2 = add(T.sw, const Offset(640, 300));
    final b = add(T.pc, const Offset(820, 300), ip: '192.168.2.2', gw: '192.168.2.1');
    setState(() {
      links..add(Link(a.id, s1.id, 0))..add(Link(s1.id, r.id, 0))..add(Link(r.id, s2.id, 0))..add(Link(s2.id, b.id, 0));
      notes.add(Note(const Offset(300, 180), 'Setting router: g0/0 = 192.168.1.1, g0/1 = 192.168.2.1'));
    });
  }

  /// Daftar contoh lab + projek tersimpan.
  Future<void> projects() async {
    final sp = await SharedPreferences.getInstance();
    final ks = sp.getKeys().where((k) => k.startsWith('p_')).toList();
    if (!mounted) return;
    showModalBottomSheet(context: context, backgroundColor: kCard, builder: (_) => ListView(children: [
          const ListTile(title: Text('Contoh Lab', style: TextStyle(color: kAcc))),
          ListTile(leading: const Icon(Icons.science), title: const Text('Lab 2 PC 1 Switch'), onTap: () { Navigator.pop(context); lab1(); }),
          ListTile(leading: const Icon(Icons.science), title: const Text('Lab 2 Jaringan 1 Router'), onTap: () { Navigator.pop(context); lab2(); }),
          const ListTile(title: Text('Projek tersimpan', style: TextStyle(color: kAcc))),
          for (final k in ks)
            ListTile(
                title: Text(k.substring(2)), onTap: () { Navigator.pop(context); fromJ(jsonDecode(sp.getString(k)!)); },
                trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () { sp.remove(k); Navigator.pop(context); })),
        ]));
  }

  String hint() => switch (tool) {
        Tool.select => 'Geser device / tap untuk setting IP', Tool.hand => 'Geser canvas dengan 1 jari',
        Tool.delete => 'Tap device untuk menghapus', Tool.inspect => 'Tap device untuk lihat config',
        Tool.note => 'Tap canvas untuk tambah catatan', Tool.ping => first == null ? 'Ping: pilih device asal' : 'Ping: pilih device tujuan',
        Tool.cable => first == null ? 'Kabel ${cbl[cable].$1}: pilih device pertama' : 'Pilih device kedua',
      };

  /// Gambar satu device (icon flat + nama), bisa di-drag.
  Widget devW(Dev d) => Positioned(
      left: d.pos.dx, top: d.pos.dy, width: 72,
      child: GestureDetector(
        onTap: () => tap(d), onLongPress: () => menu(d),
        onPanUpdate: tool == Tool.select ? (u) => setState(() => d.pos += u.delta / ctrl.value.getMaxScaleOnAxis()) : null,
        child: Column(children: [
          Container(
              width: 60, height: 60,
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: first == d.id ? Colors.white : kAcc, width: 1.5),
                  boxShadow: [BoxShadow(color: kAcc.withAlpha(60), blurRadius: 12)]),
              child: Icon(tInfo[d.t]!.$2, size: 32, color: netDev(d.t) ? kAcc : Colors.white)),
          const SizedBox(height: 4),
          Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        ]),
      ));

  Widget noteW(Note n) => Positioned(
      left: n.pos.dx, top: n.pos.dy,
      child: GestureDetector(
          onLongPress: () => setState(() => notes.remove(n)),
          child: Container(
              padding: const EdgeInsets.all(8), constraints: const BoxConstraints(maxWidth: 200),
              decoration: BoxDecoration(color: const Color(0xFF3A3410), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.amber)),
              child: Text(n.text, style: const TextStyle(fontSize: 12)))));

  @override
  Widget build(BuildContext context) {
    const tools = {Tool.select: Icons.near_me, Tool.hand: Icons.pan_tool, Tool.delete: Icons.delete, Tool.inspect: Icons.search, Tool.note: Icons.sticky_note_2, Tool.ping: Icons.mail_outline};
    Widget nav(IconData i, String t, VoidCallback f, {bool on = false}) => Expanded(
        child: InkWell(onTap: f, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, color: on ? kAcc : Colors.white70), Text(t, style: TextStyle(fontSize: 11, color: on ? kAcc : Colors.white70)),
        ]))));
    return Scaffold(
      appBar: AppBar(backgroundColor: kBg, title: const Text('Reyz Tracer Simulation', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)), actions: [
        IconButton(icon: const Icon(Icons.folder_open), tooltip: 'Projek & Lab', onPressed: projects),
        IconButton(icon: const Icon(Icons.calculate), tooltip: 'Kalkulator Subnet', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalcPage()))),
        IconButton(icon: const Icon(Icons.menu_book), tooltip: 'Panduan', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GuidePage()))),
      ]),
      body: Stack(children: [
        InteractiveViewer(
          transformationController: ctrl, constrained: false, minScale: .3, maxScale: 2.5, panEnabled: tool == Tool.hand, boundaryMargin: const EdgeInsets.all(400),
          child: SizedBox(width: 3000, height: 3000, child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (u) { if (tool == Tool.note) addNote(u.localPosition); },
            child: Stack(children: [
              Positioned.fill(child: AnimatedBuilder(animation: an, builder: (_, __) => CustomPaint(painter: Pt(devs, links, run, an.value)))),
              for (final n in notes) noteW(n),
              for (final d in devs) devW(d),
            ]),
          )),
        ),
        Positioned(top: 8, left: 0, right: 0, child: Center(child: Container(
            decoration: BoxDecoration(color: kCard.withAlpha(235), borderRadius: BorderRadius.circular(14)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final e in tools.entries)
                IconButton(tooltip: e.key.name, color: tool == e.key ? kAcc : Colors.white70, icon: Icon(e.value), onPressed: () => setState(() { tool = e.key; first = null; })),
            ])))),
        Positioned(bottom: 8, left: 0, right: 0, child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: kCard.withAlpha(220), borderRadius: BorderRadius.circular(20)),
            child: Text(hint(), style: const TextStyle(fontSize: 12))))),
      ]),
      bottomNavigationBar: Container(color: kCard, child: SafeArea(child: Row(children: [
        nav(Icons.add_box, 'Tambah', addSheet),
        nav(Icons.cable, 'Kabel', cableSheet, on: tool == Tool.cable),
        nav(Icons.delete, 'Hapus', () => setState(() { tool = Tool.delete; first = null; }), on: tool == Tool.delete),
        nav(Icons.play_arrow, 'Play', play),
        nav(Icons.save, 'Save', save),
      ]))),
    );
  }
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
    for (double x = 0; x < sz.width; x += 50) for (double y = 0; y < sz.height; y += 50) dots.add(Offset(x, y));
    cv.drawPoints(ui.PointMode.points, dots, Paint()..color = Colors.white12..strokeWidth = 2..strokeCap = StrokeCap.round);
    final mp = {for (final d in devs) d.id: d};
    for (final l in links) {
      final a = mp[l.a]!.pos + _o, b = mp[l.b]!.pos + _o;
      final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.5;
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
          final mid = (a + b) / 2, v = b - a, len = v.distance == 0 ? 1 : v.distance;
          final n = Offset(-v.dy, v.dx) / len * 40;
          dash(cv, Path()..moveTo(a.dx, a.dy)..quadraticBezierTo(mid.dx + n.dx, mid.dy + n.dy, b.dx, b.dy), p..color = Colors.cyanAccent);
      }
      for (final e in [[a, b], [b, a]]) { // titik ijo = kabel tersambung
        final u = e[1] - e[0];
        cv.drawCircle(e[0] + u / (u.distance == 0 ? 1 : u.distance) * 34, 5, Paint()..color = Colors.greenAccent);
      }
    }
    final r = run;
    if (r != null && r.path.length > 1 && r.path.every(mp.containsKey)) { // paket biru jalan
      final pts = r.path.map((i) => mp[i]!.pos + _o).toList();
      final n = pts.length - 1, f = (t * n).clamp(0.0, n - 0.0001).toDouble(), i = f.floor();
      final q = Offset.lerp(pts[i], pts[i + 1], f - i)!;
      cv.drawCircle(q, 13, Paint()..color = kAcc.withAlpha(90)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      cv.drawCircle(q, 6, Paint()..color = const Color(0xFF3DA5FF));
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter o) => true;
}

/// Popup setting device: tab Config + Command Prompt / CLI.
class DevDialog extends StatefulWidget {
  final Dev d; final SimState s; final VoidCallback refresh;
  const DevDialog(this.d, this.s, this.refresh, {super.key});
  @override
  State<DevDialog> createState() => _DevDlgState();
}

class _DevDlgState extends State<DevDialog> {
  Dev get d => widget.d;
  late final n = TextEditingController(text: d.name), ip = TextEditingController(text: d.ip),
      mk = TextEditingController(text: d.mask), gw = TextEditingController(text: d.gw), cmd = TextEditingController();
  final sc = ScrollController(), fn = FocusNode();

  @override
  void initState() {
    super.initState();
    if (d.log.isEmpty) d.log.add(d.t == T.router ? 'Reyz Router CLI\nKetik: enable, conf t, interface g0/0, ip address <ip> <mask>, no shutdown, do show ip route\n' : 'Reyz Command Prompt\nKetik: ping <ip>, ipconfig, cls\n');
  }

  /// Simpan isian Config langsung saat diketik.
  void save() {
    d.name = n.text; d.ip = ip.text.trim(); d.mask = mk.text.trim(); d.gw = gw.text.trim();
    widget.refresh();
  }

  Widget field(TextEditingController c, String l) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(controller: c, onChanged: (_) => save(), keyboardType: l == 'Nama Device' ? null : TextInputType.number, decoration: InputDecoration(labelText: l, border: const OutlineInputBorder())));

  Widget config() => ListView(padding: const EdgeInsets.all(12), children: [
        field(n, 'Nama Device'),
        if (!netDev(d.t)) ...[field(ip, 'IP Address'), field(mk, 'Subnet Mask'), field(gw, 'Gateway')],
        if (d.t == T.router) ...[
          const Text('Interface (atur lewat tab CLI):'),
          for (final e in d.ifs.entries) Text('${e.key}: ${e.value.ip.isEmpty ? 'belum diatur' : '${e.value.ip} / ${e.value.mask}'} (${e.value.up ? 'up' : 'down'})'),
        ],
        if (passive(d.t)) const Text('Device ini tidak butuh IP. Cukup sambungkan kabel.'),
      ]);

  Widget term() => Column(children: [
        Expanded(child: Container(
            color: Colors.black, width: double.infinity, padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(controller: sc, child: Text(d.log.join('\n'), style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12))))),
        TextField(
            controller: cmd, focusNode: fn, autocorrect: false,
            decoration: InputDecoration(prefixText: widget.s.prompt(d), hintText: 'ketik perintah'),
            onSubmitted: (v) {
              setState(() {
                d.log.add('${widget.s.prompt(d)}$v');
                final o = widget.s.cli(d, v);
                if (o == '\u0000') d.log.clear(); else if (o.isNotEmpty) d.log.add(o);
              });
              cmd.clear(); fn.requestFocus(); widget.refresh();
              WidgetsBinding.instance.addPostFrameCallback((_) { if (sc.hasClients) sc.jumpTo(sc.position.maxScrollExtent); });
            }),
      ]);

  @override
  Widget build(BuildContext context) {
    final cli = !passive(d.t);
    final tabs = ['Config', if (cli) d.t == T.router ? 'CLI' : 'Command Prompt'];
    return Dialog(
        backgroundColor: kCard, insetPadding: const EdgeInsets.all(12),
        child: SizedBox(height: 480, child: DefaultTabController(length: tabs.length, child: Column(children: [
          Padding(padding: const EdgeInsets.all(12), child: Text(d.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          TabBar(tabs: [for (final t in tabs) Tab(text: t)]),
          Expanded(child: TabBarView(children: [config(), if (cli) term()])),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup')),
        ]))));
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
        SelectableText(out, style: const TextStyle(fontFamily: 'monospace', fontSize: 14, color: kAcc)),
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
          'TIPS\n\n'
          'Tekan lama device untuk ganti nama / hapus. Tool Hand untuk geser canvas, cubit 2 jari untuk zoom. '
          'Tool Ping (amplop) kirim PDU dari device asal ke tujuan.',
          style: TextStyle(height: 1.5))));
}
