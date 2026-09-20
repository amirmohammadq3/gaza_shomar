import 'dart:convert';
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
  /// و بعد از هر دو، اجازه‌ی روشن‌ماندن در پس‌زمینه (نادیده‌گرفتن بهینه‌سازی باتری)
  static Future<bool> requestPermissions() async {
    await _ensureInit();
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    bool granted = true;
    try {
      granted = await androidImpl?.requestNotificationsPermission() ?? true;
    } catch (_) {}
    try {
      await androidImpl?.requestExactAlarmsPermission();
    } catch (_) {}
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
    appState.load();
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
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('قضاشمار', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
                SizedBox(height: 2),
                Text('مدیریت نماز و روزه قضا', style: TextStyle(color: Colors.white70, fontSize: 11.5)),
              ],
            ),
            Positioned(
              right: 0,
              child: GestureDetector(
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
            ),
            Positioned(
              left: 0,
              child: _buildNotifToggle(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleNotifications(BuildContext context, bool value) async {
    appState.vibrate();
    if (value) {
      final granted = await PrayerNotify.requestPermissions();
      await appState.setNotifications(true);
      await PrayerNotify.rescheduleAll();
      if (!granted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اجازه‌ی نمایش اعلان از تنظیمات گوشی داده نشد؛ برای دریافت یادآوری‌ها آن را از تنظیمات فعال کنید.')),
        );
      }
    } else {
      await appState.setNotifications(false);
      await PrayerNotify.cancelAll();
    }
  }

  Widget _buildNotifToggle(BuildContext context) {
    final on = appState.notificationsOn;
    return GestureDetector(
      onTap: () => _toggleNotifications(context, !on),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.28),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('اعلان‌ها', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(width: 2),
              Transform.scale(
                scale: 0.7,
                child: Switch(
                  value: on,
                  activeColor: const Color(0xFF3E64FF),
                  onChanged: (v) => _toggleNotifications(context, v),
                ),
              ),
            ],
          ),
        ),
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
    final showToggle = kFardIds.contains(cat.id);
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
