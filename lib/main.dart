import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const QazaShomarApp());
}

/// -------------------- تبدیل تاریخ میلادی به شمسی (بدون پکیج جانبی) --------------------
class Jalali {
  final int year, month, day;
  const Jalali(this.year, this.month, this.day);

  static Jalali fromDateTime(DateTime g) {
    final gy = g.year, gm = g.month, gd = g.day;
    final gDaysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    int gy2 = (gm > 2) ? (gy + 1) : gy;
    int days = 355666 +
        (365 * gy) +
        ((gy2 + 3) ~/ 4) -
        ((gy2 + 99) ~/ 100) +
        ((gy2 + 399) ~/ 400) +
        gd +
        gDaysInMonth.sublist(0, gm - 1).fold(0, (a, b) => a + b);
    int jy = -1595 + (33 * (days ~/ 12053));
    days %= 12053;
    jy += 4 * (days ~/ 1461);
    days %= 1461;
    if (days > 365) {
      jy += (days - 1) ~/ 365;
      days = (days - 1) % 365;
    }
    int jm;
    int jd;
    if (days < 186) {
      jm = 1 + (days ~/ 31);
      jd = 1 + (days % 31);
    } else {
      jm = 7 + ((days - 186) ~/ 30);
      jd = 1 + ((days - 186) % 30);
    }
    return Jalali(jy, jm, jd);
  }

  static const monthNames = [
    'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور',
    'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند'
  ];

  String get monthName => monthNames[month - 1];
}

String toFarsiDigits(dynamic n) {
  const en = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
  const fa = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
  var s = n.toString();
  for (var i = 0; i < en.length; i++) {
    s = s.replaceAll(en[i], fa[i]);
  }
  return s;
}

String formatJalaliDate(DateTime dt) {
  final j = Jalali.fromDateTime(dt);
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '${toFarsiDigits(j.day)} ${j.monthName} ${toFarsiDigits(j.year)} — ${toFarsiDigits(hh)}:${toFarsiDigits(mm)}';
}

/// -------------------- مدل دسته‌بندی --------------------
class QazaCategory {
  final String id;
  final String title;
  final String shortLabel;
  final Color color;
  final IconData icon;
  const QazaCategory(this.id, this.title, this.shortLabel, this.color, this.icon);
}

const List<QazaCategory> kCategories = [
  QazaCategory('sobh', 'نماز قضای صبح', 'صبح', Color(0xFF2ECC71), Icons.wb_twilight),
  QazaCategory('zohr', 'نماز قضای ظهر', 'ظهر', Color(0xFFF1C40F), Icons.wb_sunny),
  QazaCategory('asr', 'نماز قضای عصر', 'عصر', Color(0xFFE74C3C), Icons.wb_cloudy),
  QazaCategory('maghrib', 'نماز قضای مغرب', 'مغرب', Color(0xFF3498DB), Icons.nightlight_round),
  QazaCategory('isha', 'نماز قضای عشاء', 'عشاء', Color(0xFF1ABC9C), Icons.dark_mode),
  QazaCategory('ayat', 'نماز آیات', 'آیات', Color(0xFF9B59B6), Icons.flash_on),
  QazaCategory('rozeh', 'روزه قضا', 'روزه قضا', Color(0xFFE67E22), Icons.wb_sunny_outlined),
];

/// شناسه‌ی نمازهای پنج‌گانه (برای بخش «کامل/شکسته» و اعلان‌ها)
const Set<String> kFardIds = {'sobh', 'zohr', 'asr', 'maghrib', 'isha'};

/// فقط نمازهای چهار رکعتی (ظهر، عصر، عشا) شکسته دارند؛ صبح و مغرب شکسته ندارند
const Set<String> kQasrIds = {'zohr', 'asr', 'isha'};

const String kAppVersion = '2.0.0';

/// -------------------- یک رکورد تاریخچه --------------------
class HistoryEntry {
  final String categoryId;
  final bool isAdd;
  final int amount;
  final DateTime time;
  final bool isBroken;

  HistoryEntry({
    required this.categoryId,
    required this.isAdd,
    required this.amount,
    required this.time,
    this.isBroken = false,
  });

  Map<String, dynamic> toJson() => {
        'c': categoryId,
        'a': isAdd,
        'n': amount,
        't': time.toIso8601String(),
        'b': isBroken,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        categoryId: j['c'] as String,
        isAdd: j['a'] as bool,
        amount: j['n'] as int,
        time: DateTime.parse(j['t'] as String),
        isBroken: j['b'] as bool? ?? false,
      );
}

/// -------------------- وضعیت و ذخیره‌سازی دائمی --------------------
class AppState extends ChangeNotifier {
  final Map<String, int> totalAdded = {};
  final Map<String, int> totalRemoved = {};
  final Map<String, int> totalAddedBroken = {};
  final Map<String, int> totalRemovedBroken = {};
  final List<HistoryEntry> history = [];
  bool loaded = false;
  bool vibrationOn = true;
  bool notificationsOn = false;
  bool weeklyBackupOn = false;
  DateTime? lastBackupTime; // آخرین پشتیبان‌گیری (دستی یا هفتگی)
  DateTime? lastWeeklyTime; // آخرین پشتیبان‌گیری خودکار هفتگی

  int currentOf(String id) => (totalAdded[id] ?? 0) - (totalRemoved[id] ?? 0);
  int currentBrokenOf(String id) {
    final v = (totalAddedBroken[id] ?? 0) - (totalRemovedBroken[id] ?? 0);
    return v < 0 ? 0 : v;
  }

  double percentOf(String id) {
    final add = totalAdded[id] ?? 0;
    if (add <= 0) return 0;
    final rem = totalRemoved[id] ?? 0;
    return (rem / add).clamp(0.0, 1.0);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final cat in kCategories) {
      totalAdded[cat.id] = prefs.getInt('added_${cat.id}') ?? 0;
      totalRemoved[cat.id] = prefs.getInt('removed_${cat.id}') ?? 0;
      totalAddedBroken[cat.id] = prefs.getInt('addedBroken_${cat.id}') ?? 0;
      totalRemovedBroken[cat.id] = prefs.getInt('removedBroken_${cat.id}') ?? 0;
    }
    vibrationOn = prefs.getBool('vibration') ?? true;
    notificationsOn = prefs.getBool('notifications') ?? false;
    weeklyBackupOn = prefs.getBool('weekly_backup') ?? false;
    final lb = prefs.getInt('last_backup_ms');
    lastBackupTime = lb == null ? null : DateTime.fromMillisecondsSinceEpoch(lb);
    final lw = prefs.getInt('last_weekly_ms');
    lastWeeklyTime = lw == null ? null : DateTime.fromMillisecondsSinceEpoch(lw);
    final histRaw = prefs.getString('history');
    if (histRaw != null) {
      try {
        final list = jsonDecode(histRaw) as List;
        history.addAll(list.map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>)));
      } catch (_) {}
    }
    loaded = true;
    notifyListeners();
    if (notificationsOn) {
      // شمارش‌های ذخیره‌شده رو با اعلان‌های زمان‌بندی‌شده هماهنگ کن
      PrayerNotify.rescheduleAll();
    }
  }

  Future<void> _persistTotals(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('added_$id', totalAdded[id] ?? 0);
    await prefs.setInt('removed_$id', totalRemoved[id] ?? 0);
    await prefs.setInt('addedBroken_$id', totalAddedBroken[id] ?? 0);
    await prefs.setInt('removedBroken_$id', totalRemovedBroken[id] ?? 0);
  }

  Future<void> _persistHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(history.map((e) => e.toJson()).toList());
    await prefs.setString('history', encoded);
  }

  Future<void> addToCategory(String id, int amount, {bool isBroken = false}) async {
    totalAdded[id] = (totalAdded[id] ?? 0) + amount;
    if (isBroken) {
      totalAddedBroken[id] = (totalAddedBroken[id] ?? 0) + amount;
    }
    history.insert(0, HistoryEntry(categoryId: id, isAdd: true, amount: amount, time: DateTime.now(), isBroken: isBroken));
    notifyListeners();
    await _persistTotals(id);
    await _persistHistory();
    if (notificationsOn) {
      await PrayerNotify.rescheduleOne(id);
    }
  }

  Future<void> removeFromCategory(String id, int amount, {bool isBroken = false}) async {
    final current = currentOf(id);
    final actual = amount > current ? current : amount;
    if (actual <= 0) return;
    totalRemoved[id] = (totalRemoved[id] ?? 0) + actual;
    if (isBroken) {
      final curBroken = currentBrokenOf(id);
      final actualBroken = actual > curBroken ? curBroken : actual;
      totalRemovedBroken[id] = (totalRemovedBroken[id] ?? 0) + actualBroken;
    }
    history.insert(0, HistoryEntry(categoryId: id, isAdd: false, amount: actual, time: DateTime.now(), isBroken: isBroken));
    notifyListeners();
    await _persistTotals(id);
    await _persistHistory();
    if (notificationsOn) {
      await PrayerNotify.rescheduleOne(id);
    }
  }

  Future<void> setVibration(bool v) async {
    vibrationOn = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vibration', v);
  }

  Future<void> setNotifications(bool v) async {
    notificationsOn = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications', v);
  }

  Future<void> setWeeklyBackup(bool v) async {
    weeklyBackupOn = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('weekly_backup', v);
  }

  Future<void> markBackupDone({required bool weekly}) async {
    final now = DateTime.now();
    lastBackupTime = now;
    if (weekly) lastWeeklyTime = now;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_backup_ms', now.millisecondsSinceEpoch);
    if (weekly) await prefs.setInt('last_weekly_ms', now.millisecondsSinceEpoch);
  }

  /// جایگزینی کامل اطلاعات برنامه با اطلاعات یک فایل پشتیبان
  Future<void> restoreFromBackup(BackupData d) async {
    final prefs = await SharedPreferences.getInstance();
    for (final cat in kCategories) {
      totalAdded[cat.id] = d.added[cat.id] ?? 0;
      totalRemoved[cat.id] = d.removed[cat.id] ?? 0;
      totalAddedBroken[cat.id] = d.addedBroken[cat.id] ?? 0;
      totalRemovedBroken[cat.id] = d.removedBroken[cat.id] ?? 0;
      await _persistTotals(cat.id);
    }
    history
      ..clear()
      ..addAll(d.history);
    await _persistHistory();
    notifyListeners();
    if (notificationsOn) {
      await PrayerNotify.rescheduleAll();
    }
    // (prefs برای اطمینان از ثبت نهایی)
    await prefs.reload();
  }

  Future<void> vibrate() async {
    if (!vibrationOn) return;
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(duration: 16, amplitude: 110);
        return;
      }
    } catch (_) {}
    HapticFeedback.selectionClick();
  }
}

final appState = AppState();

/// -------------------- اعلان‌های روزانه‌ی نماز قضا --------------------
class PrayerNotify {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  // شناسه‌ی یکتا برای هر نماز، برای اینکه هر بار زمان‌بندی مجدد، قبلی را جایگزین کند
  static const Map<String, int> _ids = {
    'sobh': 9001,
    'zohr': 9002,
    'asr': 9003,
    'maghrib': 9004,
    'isha': 9005,
  };

  // ساعت ارسال هر اعلان [ساعت, دقیقه]
  static const Map<String, List<int>> _times = {
    'sobh': [6, 0],
    'zohr': [12, 0],
    'asr': [15, 0],
    'maghrib': [18, 0],
    'isha': [20, 0],
  };

  static const Map<String, String> _emoji = {
    'sobh': '🌅',
    'zohr': '☀️',
    'asr': '🌤️',
    'maghrib': '🌇',
    'isha': '🌙',
  };

  static const Map<String, String> _label = {
    'sobh': 'صبح',
    'zohr': 'ظهر',
    'asr': 'عصر',
    'maghrib': 'مغرب',
    'isha': 'عشا',
  };

  static const Map<String, String> _tail = {
    'sobh': 'وقتشه برای ادای قضای نمازت قدمی برداری 🤲',
    'zohr': 'با نیت قربت به خدا، به‌تدریج قضاهات رو ادا کن 🤲',
    'asr': 'هر نماز قضا، فرصتی برای جبران و نزدیک‌تر شدن به خداست 🤲',
    'maghrib': 'با یاد خدا، قضای نمازت رو در برنامه‌ات قرار بده 🤲',
    'isha': 'امروز هم می‌تونی قدمی برای ادای نمازهای قضات برداری 🤲',
  };

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Tehran'));
    } catch (_) {}
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  /// اجازه‌ی نمایش اعلان (اندروید ۱۳ به بعد)، اجازه‌ی زمان‌بندی دقیق،
  /// و بعد از هر دو، اجازه‌ی روشن‌ماندن در پس‌زمینه (نادیده‌گرفتن بهینه‌سازی باتری).
  /// اگه اجازه‌ی اعلان قبلاً (توی یکی از تست‌های قبلی) برای همیشه رد شده باشه،
  /// اندروید دیگه هیچ‌وقت دیالوگش رو نشون نمی‌ده؛ توی این حالت کاربر رو مستقیم
  /// می‌بریم به صفحه‌ی تنظیمات خودِ اپ تا دستی روشنش کنه.
  static Future<bool> requestPermissions() async {
    await _ensureInit();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    final notifStatus = await Permission.notification.status;
    if (notifStatus.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }

    bool granted = true;
    try {
      granted = await androidImpl?.requestNotificationsPermission() ?? true;
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
    try {
      await androidImpl?.requestExactAlarmsPermission();
    } catch (_) {}
    await Future.delayed(const Duration(seconds: 1));
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
    return granted;
  }

  static Future<void> cancelAll() async {
    await _ensureInit();
    for (final id in _ids.values) {
      await _plugin.cancel(id);
    }
  }

  static Future<void> rescheduleAll() async {
    await _ensureInit();
    for (final catId in _ids.keys) {
      await _rescheduleOne(catId);
    }
  }

  static Future<void> rescheduleOne(String catId) async {
    if (!_ids.containsKey(catId)) return;
    await _ensureInit();
    await _rescheduleOne(catId);
  }

  static Future<void> _rescheduleOne(String catId) async {
    final id = _ids[catId]!;
    if (!appState.notificationsOn) {
      await _plugin.cancel(id);
      return;
    }
    final count = appState.currentOf(catId);
    if (count <= 0) {
      await _plugin.cancel(id);
      return;
    }
    final hm = _times[catId]!;
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, hm[0], hm[1]);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    final countFa = toFarsiDigits(count);
    final plainBody = '${_emoji[catId]} شما $countFa نماز قضای ${_label[catId]} دارید.\n${_tail[catId]}';
    final htmlBody =
        '<b>${_emoji[catId]} شما <font color="#FFCC33">$countFa</font> نماز قضای ${_label[catId]} دارید.<br>${_tail[catId]}</b>';
    await _plugin.zonedSchedule(
      id,
      'قضاشمار',
      plainBody,
      scheduled,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'qaza_reminders',
          'یادآوری نماز‌های قضا',
          channelDescription: 'یادآوری روزانه برای ادای نماز‌های قضا',
          importance: Importance.max,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(
            htmlBody,
            htmlFormatBigText: true,
            contentTitle: 'قضاشمار',
          ),
        ),
      ),
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}

/// -------------------- اپ --------------------
class QazaShomarApp extends StatefulWidget {
  const QazaShomarApp({super.key});
  @override
  State<QazaShomarApp> createState() => _QazaShomarAppState();
}

class _QazaShomarAppState extends State<QazaShomarApp> {
  @override
  void initState() {
    super.initState();
    appState.load().then((_) => BackupService.onLaunch());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'قضاشمار',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF3E64FF),
        scaffoldBackgroundColor: const Color(0xFFF3F5FA),
        fontFamily: null,
      ),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const HomeScreen(),
    );
  }
}

/// میکسین واکنش‌گر به appState
mixin AppStateListenerMixin<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    appState.addListener(_onAppStateChanged);
  }

  void _onAppStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appState.removeListener(_onAppStateChanged);
    super.dispose();
  }
}

/// -------------------- صفحه اصلی --------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with AppStateListenerMixin, SingleTickerProviderStateMixin {
  late final AnimationController _chartCtrl;

  @override
  void initState() {
    super.initState();
    _chartCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  }

  @override
  void dispose() {
    _chartCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  void _runChartAnim() {
    _chartCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!appState.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_chartCtrl.status == AnimationStatus.dismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runChartAnim());
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            _buildChart(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                itemCount: kCategories.length,
                itemBuilder: (context, i) => CategoryCard(category: kCategories[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFF3E64FF), Color(0xFF5EA1FF)],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              appState.vibrate();
              Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()));
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.18)),
              child: const Icon(Icons.history, color: Colors.white, size: 22),
            ),
          ),
          const Spacer(),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('قضاشمار', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
              SizedBox(height: 2),
              Text('مدیریت نماز و روزه قضا', style: TextStyle(color: Colors.white70, fontSize: 11.5)),
            ],
          ),
          const Spacer(),
          GestureDetector(
            onTap: () {
              appState.vibrate();
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.18)),
              child: const Icon(Icons.settings, color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart() {
    final maxVal = kCategories.map((c) => appState.currentOf(c.id)).fold<int>(0, (a, b) => a > b ? a : b);
    final axisMax = maxVal <= 0 ? 10 : (((maxVal / 5).ceil()) * 5) + (maxVal % 5 == 0 ? 5 : 0);
    const gridSteps = 5;
    const barAreaHeight = 118.0;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      padding: const EdgeInsets.fromLTRB(10, 16, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      height: 210,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: barAreaHeight + 22,
            child: Column(
              children: List.generate(gridSteps + 1, (i) {
                return Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: Color(0xFFEDEFF5), width: 1)),
                    ),
                  ),
                );
              }),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: _chartCtrl,
              builder: (context, _) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: kCategories.map((cat) {
                    final val = appState.currentOf(cat.id);
                    final frac = axisMax == 0 ? 0.0 : (val / axisMax).clamp(0.0, 1.0);
                    final barHeight = frac * _chartCtrl.value * barAreaHeight;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              toFarsiDigits(val),
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: cat.color),
                            ),
                            const SizedBox(height: 3),
                            SizedBox(
                              height: barHeight,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: cat.color,
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              cat.shortLabel,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 9.5, color: Color(0xFF8A8FA3)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
/// -------------------- کارت هر دسته --------------------
class CategoryCard extends StatefulWidget {
  final QazaCategory category;
  const CategoryCard({super.key, required this.category});

  @override
  State<CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<CategoryCard> with AppStateListenerMixin {
  Future<({int amount, bool isBroken})?> _showAmountDialog({required bool isAdd}) async {
    final controller = TextEditingController(text: '1');
    final cat = widget.category;
    final showToggle = kQasrIds.contains(cat.id);
    bool isBroken = false;
    return showDialog<({int amount, bool isBroken})>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Widget seg(String label, bool active, VoidCallback onTap) {
              return GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: active ? cat.color : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: active ? Colors.white : const Color(0xFF8A8FA3),
                    ),
                  ),
                ),
              );
            }

            final brokenCount = appState.currentBrokenOf(cat.id);

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              title: Text(
                isAdd ? 'افزودن به «${cat.title}»' : 'کم‌کردن از «${cat.title}»',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showToggle) ...[
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F1F6),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4, offset: const Offset(0, 2))],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              seg('کامل', !isBroken, () => setDialogState(() => isBroken = false)),
                              seg('شکسته', isBroken, () => setDialogState(() => isBroken = true)),
                            ],
                          ),
                        ),
                        const Spacer(),
                        if (brokenCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 5, offset: const Offset(0, 2))],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('قضای شکسته', style: TextStyle(fontSize: 9, color: Color(0xFF8A8FA3))),
                                Text(
                                  toFarsiDigits(brokenCount),
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF2B2F42)),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    autofocus: true,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      hintText: 'تعداد',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [1, 5, 10, 50, 100].map((n) {
                      return GestureDetector(
                        onTap: () {
                          final cur = int.tryParse(controller.text) ?? 0;
                          controller.text = (cur + n).toString();
                        },
                        child: Chip(label: Text('+${toFarsiDigits(n)}')),
                      );
                    }).toList(),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('لغو')),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: isAdd ? cat.color : Colors.redAccent),
                  onPressed: () {
                    final v = int.tryParse(controller.text) ?? 0;
                    Navigator.pop(context, (amount: v, isBroken: showToggle && isBroken));
                  },
                  child: Text(isAdd ? 'تایید و افزودن' : 'تایید و کم‌کردن'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _onAdd() async {
    appState.vibrate();
    final result = await _showAmountDialog(isAdd: true);
    if (result != null && result.amount > 0) {
      await appState.addToCategory(widget.category.id, result.amount, isBroken: result.isBroken);
    }
  }

  Future<void> _onRemove() async {
    appState.vibrate();
    final result = await _showAmountDialog(isAdd: false);
    if (result != null && result.amount > 0) {
      await appState.removeFromCategory(widget.category.id, result.amount, isBroken: result.isBroken);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    final current = appState.currentOf(cat.id);
    final percent = appState.percentOf(cat.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: cat.color.withOpacity(0.15), shape: BoxShape.circle),
                child: Icon(cat.icon, color: cat.color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(cat.title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
              ),
              Text(
                toFarsiDigits(current),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cat.color),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: percent),
              duration: const Duration(milliseconds: 600),
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 8,
                backgroundColor: cat.color.withOpacity(0.12),
                valueColor: AlwaysStoppedAnimation(cat.color),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${toFarsiDigits((percent * 100).round())}٪ انجام‌شده',
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF8A8FA3)),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _onAdd,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cat.color,
                    side: BorderSide(color: cat.color.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('افزودن'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _onRemove,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: BorderSide(color: Colors.redAccent.withOpacity(0.4)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.remove, size: 18),
                  label: const Text('کم کردن'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
/// -------------------- صفحه تاریخچه --------------------
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with AppStateListenerMixin {
  QazaCategory _catById(String id) => kCategories.firstWhere((c) => c.id == id, orElse: () => kCategories.first);

  @override
  Widget build(BuildContext context) {
    final history = appState.history;
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFF3E64FF), Color(0xFF5EA1FF)]),
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(Icons.arrow_forward, color: Colors.white),
                  ),
                  const Spacer(),
                  const Text('تاریخچه', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  const SizedBox(width: 22),
                ],
              ),
            ),
            Expanded(
              child: history.isEmpty
                  ? const Center(
                      child: Text('هنوز رکوردی ثبت نشده است.', style: TextStyle(color: Color(0xFF8A8FA3))),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: history.length,
                      itemBuilder: (context, i) {
                        final e = history[i];
                        final cat = _catById(e.categoryId);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6)],
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: (e.isAdd ? Colors.green : Colors.redAccent).withOpacity(0.12),
                                ),
                                child: Icon(
                                  e.isAdd ? Icons.add : Icons.remove,
                                  color: e.isAdd ? Colors.green : Colors.redAccent,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(cat.title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
                                        ),
                                        if (e.isBroken) ...[
                                          const SizedBox(width: 4),
                                          const Text('(شکسته)', style: TextStyle(fontSize: 11, color: Color(0xFFAFB2C0))),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      formatJalaliDate(e.time),
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF8A8FA3)),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                '${e.isAdd ? '+' : '-'}${toFarsiDigits(e.amount)}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: e.isAdd ? Colors.green : Colors.redAccent,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ==================== پشتیبان‌گیری (بک‌آپ) ====================

/// نگاشت شناسه‌ی داخلی نمازها به کلیدهای فایل پشتیبان
const Map<String, String> kBackupPrayerKeys = {
  'sobh': 'fajr',
  'zohr': 'dhuhr',
  'asr': 'asr',
  'maghrib': 'maghrib',
  'isha': 'isha',
  'ayat': 'ayat',
};

const Map<String, String> kBackupPrayerFa = {
  'sobh': 'نماز صبح',
  'zohr': 'نماز ظهر',
  'asr': 'نماز عصر',
  'maghrib': 'نماز مغرب',
  'isha': 'نماز عشا',
  'ayat': 'نماز آیات',
};

/// اطلاعاتی که از یک فایل پشتیبان خوانده می‌شود
class BackupData {
  final Map<String, int> added;
  final Map<String, int> removed;
  final Map<String, int> addedBroken;
  final Map<String, int> removedBroken;
  final List<HistoryEntry> history;
  final String createdAt;
  final String backupType;
  BackupData({
    required this.added,
    required this.removed,
    required this.addedBroken,
    required this.removedBroken,
    required this.history,
    required this.createdAt,
    required this.backupType,
  });
}

String _p2(int n) => n.toString().padLeft(2, '0');

/// «۱۴۰۵/۰۷/۰۶» با ارقام لاتین (برای فایل‌ها)
String backupDateLatin(DateTime dt) {
  final j = Jalali.fromDateTime(dt);
  return '${j.year}/${_p2(j.month)}/${_p2(j.day)}';
}

String backupTimeLatin(DateTime dt, {bool seconds = false}) =>
    '${_p2(dt.hour)}:${_p2(dt.minute)}${seconds ? ':${_p2(dt.second)}' : ''}';

/// «۱۴۰۵/۰۷/۰۶ - ۰۲:۱۰» با ارقام فارسی (برای نمایش)
String backupStampFa(DateTime dt) => toFarsiDigits('${backupDateLatin(dt)} - ${backupTimeLatin(dt)}');

class BackupService {
  static const String folderName = 'نماز و روزه قضا شمار';
  static const String folderPath = '/storage/emulated/0/$folderName';

  static String fileName(DateTime dt) {
    final j = Jalali.fromDateTime(dt);
    return 'GhazaBackup_${j.year}-${_p2(j.month)}-${_p2(j.day)}_${_p2(dt.hour)}${_p2(dt.minute)}.zip';
  }

  // ---------- دسترسی و پوشه ----------
  static Future<bool> _hasPermission() async {
    try {
      return await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestPermission() async {
    try {
      if (await Permission.manageExternalStorage.request().isGranted) return true;
    } catch (_) {}
    try {
      if (await Permission.storage.request().isGranted) return true;
    } catch (_) {}
    return _hasPermission();
  }

  /// ساخت پوشه‌ی «نماز و روزه قضا شمار» در حافظه‌ی گوشی
  static Future<bool> ensureFolder({bool ask = false}) async {
    if (!Platform.isAndroid) return false;
    try {
      var ok = await _hasPermission();
      if (!ok && ask) ok = await _requestPermission();
      if (!ok) return false;
      final dir = Directory(folderPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// موقع باز شدن برنامه: هیچ درخواست دسترسی‌ای نشان داده نمی‌شود (فقط اگر قبلاً
  /// اجازه گرفته شده بود، پوشه را می‌سازد). درخواست دسترسی فقط زمانی نشان داده
  /// می‌شود که کاربر خودش «پشتیبان‌گیری هفتگی» را روشن کند یا «پشتیبان‌گیری دستی» بزند.
  static Future<void> onLaunch() async {
    await ensureFolder(ask: false);
    await autoBackupIfDue();
  }

  static Future<bool> autoBackupIfDue() async {
    if (!appState.weeklyBackupOn) return false;
    final last = appState.lastWeeklyTime;
    final now = DateTime.now();
    if (last != null && now.difference(last).inDays < 7 && !now.isBefore(last)) return false;
    return createInFolder('weekly');
  }

  /// ساخت ZIP و ذخیره‌ی مستقیم در پوشه‌ی برنامه
  static Future<bool> createInFolder(String type) async {
    try {
      if (!await ensureFolder(ask: false)) return false;
      final now = DateTime.now();
      final bytes = buildZip(type, now);
      await File('$folderPath/${fileName(now)}').writeAsBytes(bytes, flush: true);
      await appState.markBackupDone(weekly: type == 'weekly');
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- ساخت ZIP ----------
  static Uint8List buildZip(String type, DateTime now) {
    final prayers = <String, dynamic>{};
    final progress = <String, dynamic>{};

    Map<String, dynamic> progressOf(String id) {
      final added = appState.totalAdded[id] ?? 0;
      final removed = appState.totalRemoved[id] ?? 0;
      final m = <String, dynamic>{
        'initial': added,
        'completed': removed,
        'remaining': appState.currentOf(id),
        'percentage': (appState.percentOf(id) * 100).round(),
      };
      if (kQasrIds.contains(id)) {
        m['qasr_added'] = appState.totalAddedBroken[id] ?? 0;
        m['qasr_removed'] = appState.totalRemovedBroken[id] ?? 0;
      }
      return m;
    }

    kBackupPrayerKeys.forEach((id, key) {
      final total = appState.currentOf(id);
      final qasr = kQasrIds.contains(id) ? appState.currentBrokenOf(id).clamp(0, total < 0 ? 0 : total).toInt() : 0;
      prayers[key] = {'sahih': total - qasr, 'qasr': qasr};
      progress[key] = progressOf(id);
    });
    progress['fasting'] = progressOf('rozeh');

    final fasting = {'qaza_fasting': appState.currentOf('rozeh')};

    final historyList = appState.history.map((e) {
      final isFast = e.categoryId == 'rozeh';
      final m = <String, dynamic>{
        'date': backupDateLatin(e.time),
        'time': backupTimeLatin(e.time, seconds: true),
        'type': isFast ? 'fasting' : 'prayer',
      };
      if (!isFast) {
        m['prayer'] = kBackupPrayerKeys[e.categoryId] ?? e.categoryId;
        m['status'] = e.isBroken ? 'qasr' : 'sahih';
      }
      m['action'] = e.isAdd ? 'increase' : 'decrease';
      m['amount'] = e.amount;
      m['ts'] = e.time.toIso8601String();
      return m;
    }).toList();

    final info = {
      'backup_version': 1,
      'app_name': 'نماز و روزه قضا شمار',
      'app_version': kAppVersion,
      'created_at': '${backupDateLatin(now)} ${backupTimeLatin(now, seconds: true)}',
      'backup_type': type,
    };

    final archive = Archive();
    void add(String name, String content) {
      final data = utf8.encode(content);
      archive.addFile(ArchiveFile(name, data.length, data));
    }

    add('prayers.json', jsonEncode(prayers));
    add('fasting.json', jsonEncode(fasting));
    add('history.json', jsonEncode({'history': historyList}));
    add('progress.json', jsonEncode(progress));
    add('backup_info.json', jsonEncode(info));
    add('گزارش_اطلاعات.txt', _buildReport(now));

    final out = ZipEncoder().encode(archive);
    return Uint8List.fromList(out!);
  }

  static String _buildReport(DateTime now) {
    const line = '━━━━━━━━━━━━━━━━━━';
    final b = StringBuffer();
    b.writeln('گزارش اطلاعات برنامه نماز و روزه قضا شمار');
    b.writeln();
    b.writeln('تاریخ تهیه بکاپ:');
    b.writeln(backupStampFa(now));
    b.writeln();
    b.writeln(line);
    b.writeln('نمازهای قضا');
    b.writeln(line);
    for (final id in kBackupPrayerKeys.keys) {
      final total = appState.currentOf(id);
      final qasr = kQasrIds.contains(id) ? appState.currentBrokenOf(id).clamp(0, total < 0 ? 0 : total).toInt() : 0;
      b.writeln();
      b.writeln(kBackupPrayerFa[id]);
      b.writeln('سالم: ${toFarsiDigits(total - qasr)}');
      b.writeln('شکسته: ${toFarsiDigits(qasr)}');
      b.writeln('مجموع: ${toFarsiDigits(total)}');
    }
    b.writeln();
    b.writeln(line);
    b.writeln('روزه‌های قضا');
    b.writeln(line);
    b.writeln();
    b.writeln('تعداد روزه‌های قضا:');
    b.writeln('${toFarsiDigits(appState.currentOf('rozeh'))} روز');
    b.writeln();
    b.writeln(line);
    b.writeln('نوارهای پیشرفت');
    b.writeln(line);
    b.writeln();
    for (final id in kBackupPrayerKeys.keys) {
      b.writeln('${kBackupPrayerFa[id]}: ${toFarsiDigits((appState.percentOf(id) * 100).round())}٪');
    }
    b.writeln('روزه قضا: ${toFarsiDigits((appState.percentOf('rozeh') * 100).round())}٪');
    b.writeln();
    b.writeln(line);
    b.writeln('تاریخچه ثبت‌ها');
    b.writeln(line);
    if (appState.history.isEmpty) {
      b.writeln();
      b.writeln('رکوردی ثبت نشده است.');
    }
    for (final e in appState.history) {
      final isFast = e.categoryId == 'rozeh';
      b.writeln();
      b.writeln(backupStampFa(e.time));
      b.writeln(isFast ? 'روزه قضا' : (kBackupPrayerFa[e.categoryId] ?? e.categoryId));
      if (!isFast) b.writeln(e.isBroken ? 'شکسته' : 'سالم');
      b.writeln('${e.isAdd ? 'افزایش' : 'کاهش'} ${toFarsiDigits(e.amount)} عدد');
    }
    b.writeln();
    b.writeln(line);
    b.writeln();
    b.writeln('پایان گزارش.');
    return b.toString();
  }

  // ---------- خواندن ZIP ----------
  static BackupData parseZip(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('این فایل یک ZIP معتبر نیست.');
    }

    Map<String, dynamic> readJson(String name) {
      final f = archive.findFile(name);
      if (f == null) throw FormatException('فایل «$name» داخل پشتیبان پیدا نشد.');
      try {
        return jsonDecode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>;
      } catch (_) {
        throw FormatException('فایل «$name» خراب است.');
      }
    }

    int asInt(dynamic v) => v is num ? v.toInt() : 0;

    final info = readJson('backup_info.json');
    final ver = info['backup_version'];
    if (ver is! int) throw const FormatException('اطلاعات نسخه‌ی پشتیبان معتبر نیست.');
    if (ver > 1) throw const FormatException('این پشتیبان با نسخه‌ی جدیدتری از برنامه ساخته شده است.');

    final prayers = readJson('prayers.json');
    final fasting = readJson('fasting.json');
    final progress = readJson('progress.json');
    final histJson = readJson('history.json');

    final added = <String, int>{};
    final removed = <String, int>{};
    final addedBroken = <String, int>{};
    final removedBroken = <String, int>{};

    void rebuild(String id, int current, int qasr, Map<String, dynamic>? prog) {
      if (current < 0) current = 0;
      if (qasr < 0) qasr = 0;
      if (qasr > current) qasr = current;
      var a = prog == null ? current : asInt(prog['initial']);
      if (a < current) a = current;
      added[id] = a;
      removed[id] = a - current;
      var ab = prog == null ? qasr : asInt(prog['qasr_added']);
      if (ab < qasr) ab = qasr;
      addedBroken[id] = ab;
      removedBroken[id] = ab - qasr;
    }

    for (final e in kBackupPrayerKeys.entries) {
      final p = prayers[e.value];
      if (p is! Map) throw FormatException('اطلاعات «${kBackupPrayerFa[e.key]}» در پشتیبان نیست.');
      final sahih = asInt(p['sahih']);
      final qasr = kQasrIds.contains(e.key) ? asInt(p['qasr']) : 0;
      final prog = progress[e.value];
      rebuild(e.key, sahih + qasr, qasr, prog is Map<String, dynamic> ? prog : null);
    }
    final fProg = progress['fasting'];
    rebuild('rozeh', asInt(fasting['qaza_fasting']), 0, fProg is Map<String, dynamic> ? fProg : null);

    final reverse = {for (final e in kBackupPrayerKeys.entries) e.value: e.key};
    final history = <HistoryEntry>[];
    final list = histJson['history'];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final isFast = raw['type'] == 'fasting';
        final catId = isFast ? 'rozeh' : reverse[raw['prayer']];
        if (catId == null) continue;
        DateTime? t;
        try {
          t = DateTime.parse(raw['ts'] as String);
        } catch (_) {}
        history.add(HistoryEntry(
          categoryId: catId,
          isAdd: raw['action'] == 'increase',
          amount: asInt(raw['amount']),
          time: t ?? DateTime.now(),
          isBroken: !isFast && raw['status'] == 'qasr',
        ));
      }
    }

    return BackupData(
      added: added,
      removed: removed,
      addedBroken: addedBroken,
      removedBroken: removedBroken,
      history: history,
      createdAt: (info['created_at'] ?? '').toString(),
      backupType: (info['backup_type'] ?? '').toString(),
    );
  }
}

/// -------------------- اجزای مشترک صفحات جدید --------------------
class SubPageHeader extends StatelessWidget {
  final String title;
  const SubPageHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFF3E64FF), Color(0xFF5EA1FF)]),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              appState.vibrate();
              Navigator.pop(context);
            },
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.arrow_forward, color: Colors.white),
            ),
          ),
          const Spacer(),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          const Spacer(),
          const SizedBox(width: 30),
        ],
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const SettingsTile({super.key, required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        appState.vibrate();
        onTap();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: const Color(0xFF3E64FF).withOpacity(0.10), shape: BoxShape.circle),
              child: Icon(icon, color: const Color(0xFF3E64FF), size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold))),
            const Icon(Icons.chevron_left, color: Color(0xFFAFB2C0)),
          ],
        ),
      ),
    );
  }
}

class DashedDivider extends StatelessWidget {
  const DashedDivider({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: LayoutBuilder(builder: (context, c) {
        final count = (c.maxWidth / 9).floor();
        return Row(
          children: List.generate(
            count,
            (_) => Expanded(
              child: Center(child: Container(width: 5, height: 1.2, color: const Color(0xFFCFD2DC))),
            ),
          ),
        );
      }),
    );
  }
}

/// -------------------- صفحه تنظیمات --------------------
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with AppStateListenerMixin {
  Future<void> _toggleNotifications(bool value) async {
    appState.vibrate();
    if (value) {
      final granted = await PrayerNotify.requestPermissions();
      await appState.setNotifications(true);
      await PrayerNotify.rescheduleAll();
      if (!granted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('اجازه‌ی نمایش اعلان قبلاً رد شده. شما را به تنظیمات اپ بردیم؛ از آنجا «اعلان‌ها» را روشن کنید و برگردید.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } else {
      await appState.setNotifications(false);
      await PrayerNotify.cancelAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = appState.notificationsOn;
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: SafeArea(
        child: Column(
          children: [
            const SubPageHeader(title: 'تنظیمات'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(color: const Color(0xFF3E64FF).withOpacity(0.10), shape: BoxShape.circle),
                          child: const Icon(Icons.notifications_active_outlined, color: Color(0xFF3E64FF), size: 20),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('اعلان‌ها', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
                        ),
                        Switch(
                          value: on,
                          activeColor: const Color(0xFF3E64FF),
                          onChanged: _toggleNotifications,
                        ),
                      ],
                    ),
                  ),
                  SettingsTile(
                    icon: Icons.backup_outlined,
                    title: 'پشتیبان‌گیری (بک‌آپ)',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupScreen())),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// -------------------- صفحه پشتیبان‌گیری --------------------
class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));
  }

  Future<void> _manualBackup(BuildContext context) async {
    await BackupService.ensureFolder(ask: true);
    final now = DateTime.now();
    try {
      final bytes = BackupService.buildZip('manual', now);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'ذخیره‌ی فایل پشتیبان',
        fileName: BackupService.fileName(now),
        initialDirectory: BackupService.folderPath,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (path != null) {
        await appState.markBackupDone(weekly: false);
        if (context.mounted) _snack(context, 'فایل پشتیبان ذخیره شد.');
      }
    } catch (_) {
      if (context.mounted) _snack(context, 'ذخیره‌ی فایل پشتیبان انجام نشد.');
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required Widget content,
    required String cancel,
    required String ok,
    Color okColor = const Color(0xFF3E64FF),
  }) async {
    final r = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(child: content),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: okColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _restore(BuildContext context) async {
    // برای باز کردن/انتخاب فایل نیازی به اجازه‌ی «دسترسی به همه‌ی فایل‌ها» نیست؛
    // فقط اگر قبلاً اجازه گرفته شده، پوشه را برای مسیر پیش‌فرض آماده می‌کنیم.
    await BackupService.ensureFolder(ask: false);
    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
        dialogTitle: 'انتخاب فایل پشتیبان',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        initialDirectory: BackupService.folderPath,
        withData: true,
      );
    } catch (_) {
      if (context.mounted) _snack(context, 'باز کردن فایل‌ها انجام نشد.');
      return;
    }
    if (res == null || res.files.isEmpty) return;
    final file = res.files.single;

    BackupData data;
    try {
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) bytes = await File(file.path!).readAsBytes();
      if (bytes == null) throw const FormatException('فایل خوانده نشد.');
      data = BackupService.parseZip(bytes);
    } on FormatException catch (e) {
      if (context.mounted) {
        await _confirm(context,
            title: 'فایل نامعتبر',
            content: Text(e.message, textAlign: TextAlign.center),
            cancel: 'بستن',
            ok: 'باشه');
      }
      return;
    } catch (_) {
      if (context.mounted) _snack(context, 'فایل پشتیبان خوانده نشد.');
      return;
    }
    if (!context.mounted) return;

    // مرحله ۱: نمایش نام فایل و تأیید
    final okFile = await _confirm(
      context,
      title: 'فایل انتخاب‌شده',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(file.name, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          if (data.createdAt.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('تاریخ ساخت: ${toFarsiDigits(data.createdAt)}', style: const TextStyle(fontSize: 12, color: Color(0xFF8A8FA3))),
          ],
        ],
      ),
      cancel: 'انصراف',
      ok: 'تأیید',
    );
    if (!okFile || !context.mounted) return;

    // مرحله ۲: هشدار
    final okWarn = await _confirm(
      context,
      title: '⚠️ هشدار',
      content: const Text(
        'با استفاده از فایل پشتیبان، اطلاعات فعلی\nبرنامه با اطلاعات موجود در فایل پشتیبان\nجایگزین می‌شوند.\n\n'
        'اطلاعات فعلی برنامه پس از بازیابی از بین\nخواهد رفت و قابل بازگردانی نخواهد بود.\n\n'
        'آیا از ادامه کار مطمئن هستید؟',
        textAlign: TextAlign.center,
        style: TextStyle(height: 1.8, fontSize: 13),
      ),
      cancel: 'انصراف',
      ok: 'تأیید و بازیابی',
      okColor: Colors.redAccent,
    );
    if (!okWarn || !context.mounted) return;

    // مرحله ۳: تأیید نهایی (برای جلوگیری از لمس اتفاقی)
    final okFinal = await _confirm(
      context,
      title: 'تأیید نهایی',
      content: const Text(
        'این آخرین فرصت برای لغو است.\nبا ادامه دادن، همه‌ی اطلاعات فعلی برنامه حذف می‌شود.',
        textAlign: TextAlign.center,
        style: TextStyle(height: 1.8, fontSize: 13),
      ),
      cancel: 'لغو',
      ok: 'بله، بازیابی کن',
      okColor: Colors.redAccent,
    );
    if (!okFinal || !context.mounted) return;

    try {
      await appState.restoreFromBackup(data);
    } catch (_) {
      if (context.mounted) _snack(context, 'بازیابی اطلاعات انجام نشد.');
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        content: const Text(
          '✅ بازیابی با موفقیت انجام شد\n\nاطلاعات فایل پشتیبان با موفقیت\nدر برنامه بازیابی شدند.',
          textAlign: TextAlign.center,
          style: TextStyle(height: 1.8, fontWeight: FontWeight.bold),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('باشه'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: SafeArea(
        child: Column(
          children: [
            const SubPageHeader(title: 'پشتیبان‌گیری'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SettingsTile(
                    icon: Icons.event_repeat_outlined,
                    title: 'پشتیبان‌گیری هفتگی',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WeeklyBackupScreen())),
                  ),
                  SettingsTile(
                    icon: Icons.save_alt_outlined,
                    title: 'پشتیبان‌گیری دستی',
                    onTap: () => _manualBackup(context),
                  ),
                  SettingsTile(
                    icon: Icons.menu_book_outlined,
                    title: 'آموزش پشتیبان‌گیری و بازیابی اطلاعات',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupGuideScreen())),
                  ),
                  SettingsTile(
                    icon: Icons.settings_backup_restore_outlined,
                    title: 'استفاده از فایل پشتیبان',
                    onTap: () => _restore(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// -------------------- صفحه پشتیبان‌گیری هفتگی --------------------
class WeeklyBackupScreen extends StatefulWidget {
  const WeeklyBackupScreen({super.key});
  @override
  State<WeeklyBackupScreen> createState() => _WeeklyBackupScreenState();
}

class _WeeklyBackupScreenState extends State<WeeklyBackupScreen> with AppStateListenerMixin {
  Future<void> _toggle(bool v) async {
    appState.vibrate();
    if (!v) {
      await appState.setWeeklyBackup(false);
      return;
    }
    final ok = await BackupService.ensureFolder(ask: true);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('برای ذخیره‌ی پشتیبان در پوشه‌ی «نماز و روزه قضا شمار» باید اجازه‌ی دسترسی به فایل‌ها را بدهید.')),
        );
      }
      return;
    }
    await appState.setWeeklyBackup(true);
    // اولین پشتیبان بلافاصله بعد از فعال‌سازی گرفته می‌شود
    await BackupService.createInFolder('weekly');
  }

  Widget _card(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  @override
  Widget build(BuildContext context) {
    final last = appState.lastBackupTime;
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: SafeArea(
        child: Column(
          children: [
            const SubPageHeader(title: 'پشتیبان‌گیری هفتگی'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _card([
                    Row(
                      children: [
                        const Expanded(
                          child: Text('پشتیبان‌گیری خودکار هفتگی', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        ),
                        Text(
                          appState.weeklyBackupOn ? 'فعال' : 'غیرفعال',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: appState.weeklyBackupOn ? const Color(0xFF2ECC71) : const Color(0xFF8A8FA3),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Switch(
                          value: appState.weeklyBackupOn,
                          activeColor: const Color(0xFF3E64FF),
                          onChanged: _toggle,
                        ),
                      ],
                    ),
                  ]),
                  _card([
                    const Text('آخرین پشتیبان‌گیری:', style: TextStyle(fontSize: 12, color: Color(0xFF8A8FA3))),
                    const SizedBox(height: 4),
                    Text(
                      last == null ? 'هنوز پشتیبانی گرفته نشده است' : backupStampFa(last),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const DashedDivider(),
                    const Text('محل ذخیره:', style: TextStyle(fontSize: 12, color: Color(0xFF8A8FA3))),
                    const SizedBox(height: 4),
                    const Text('پوشه «نماز و روزه قضا شمار»', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ]),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      'وقتی فعال باشد، برنامه هر هفته یک فایل ZIP جدید ایجاد می‌کند.',
                      style: TextStyle(fontSize: 12, height: 1.8, color: Color(0xFF8A8FA3)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// -------------------- صفحه آموزش --------------------
class BackupGuideScreen extends StatelessWidget {
  const BackupGuideScreen({super.key});

  Widget _stepText(String t) => Text(t, style: const TextStyle(fontSize: 13.5, height: 1.9, fontWeight: FontWeight.w600));

  Widget _image(String asset) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          // عکس‌ها اسکرین‌شات گوشی‌اند: قاب عمودی ۹:۱۶
          aspectRatio: 9 / 16,
          child: Container(
            color: const Color(0xFFEDEFF5),
            child: Image.asset(
              asset,
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, __, ___) => const Center(
                child: Text('تصویر', style: TextStyle(color: Color(0xFF8A8FA3))),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: SafeArea(
        child: Column(
          children: [
            const SubPageHeader(title: 'آموزش'),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF3E64FF), Color(0xFF5EA1FF)]),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: const Color(0xFF3E64FF).withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
                    ),
                    child: const Text(
                      'آموزش بازیابی اطلاعات با فایل پشتیبان',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 3))],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('مرحله ۱:', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3E64FF))),
                        _stepText('وارد برنامه شوید و روی آیکون «تنظیمات» ضربه بزنید.'),
                        _image('assets/amozesh1.png'),
                        const DashedDivider(),
                        const Text('مرحله ۲:', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3E64FF))),
                        _stepText('روی گزینه «پشتیبان گیری» ضربه بزنید .'),
                        const DashedDivider(),
                        const Text('مرحله ۳:', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3E64FF))),
                        _stepText(
                          'روی گزینه «استفاده از فایل پشتیبان» ضربه بزنید ، و فایل پشتیبان مورد نظر خود را انتخاب کنید. '
                          '(برای بازیابی جدیدترین اطلاعات، آخرین فایل پشتیبان را انتخاب کنید).',
                        ),
                        _image('assets/amozesh2.png'),
                        const DashedDivider(),
                        const Text(
                          '⚠️ هشدار',
                          style: TextStyle(color: Colors.red, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'با استفاده از فایل پشتیبان، اطلاعات فعلی برنامه با اطلاعات موجود در فایل پشتیبان جایگزین می‌شوند.\n\n'
                          'اطلاعات فعلی برنامه پس از بازیابی از بین خواهد رفت و قابل بازگردانی نخواهد بود.',
                          style: TextStyle(color: Colors.red, fontSize: 15, fontWeight: FontWeight.bold, height: 1.9),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
