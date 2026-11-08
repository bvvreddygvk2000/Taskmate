import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'dart:async';
import 'dart:convert';

const ink = Color(0xFF20243A);
const muted = Color(0xFF85899C);
const violet = Color(0xFF7165E3);
const canvas = Color(0xFFF6F7FB);
const mint = Color(0xFF36B69A);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var firebaseReady = false;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (_) {}
  final store = TaskStore(firebaseReady: firebaseReady);
  await store.load();
  runApp(
      ChangeNotifierProvider.value(value: store, child: const TaskMateApp()));
}

class TaskItem {
  final String id;
  String title;
  String note;
  DateTime date;
  String time;
  String category;
  int priority;
  bool done;

  TaskItem(
      {required this.id,
      required this.title,
      this.note = '',
      required this.date,
      this.time = '',
      this.category = 'Personal',
      this.priority = 1,
      this.done = false});

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'note': note,
        'date': date.toIso8601String(),
        'time': time,
        'category': category,
        'priority': priority,
        'done': done
      };

  factory TaskItem.fromJson(Map<String, dynamic> j) => TaskItem(
      id: j['id'],
      title: j['title'],
      note: j['note'] ?? '',
      date: DateTime.parse(j['date']),
      time: j['time'] ?? '',
      category: j['category'] ?? 'Personal',
      priority: j['priority'] ?? 1,
      done: j['done'] ?? false);
}

class TaskStore extends ChangeNotifier {
  TaskStore({this.firebaseReady = false}) {
    if (firebaseReady) {
      _auth = FirebaseAuth.instance;
      _firestore = FirebaseFirestore.instance;
    }
  }

  final bool firebaseReady;
  FirebaseAuth? _auth;
  FirebaseFirestore? _firestore;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _cloudSubscription;
  final List<TaskItem> tasks = [];
  DateTime selectedDate = DateUtils.dateOnly(DateTime.now());
  DateTime focusedMonth = DateUtils.dateOnly(DateTime.now());
  String query = '';
  String filter = 'All';
  bool loaded = false;
  bool showCompletedTasks = true;
  bool weekStartsMonday = false;
  bool confirmBeforeDelete = true;
  ThemeMode themeMode = ThemeMode.system;

  User? get signedInUser => _auth?.currentUser;
  bool get cloudSyncAvailable => firebaseReady;
  bool get cloudSyncEnabled => signedInUser != null;

  CollectionReference<Map<String, dynamic>> _userTasks(String uid) =>
      _firestore!.collection('users').doc(uid).collection('tasks');

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    showCompletedTasks = prefs.getBool('show_completed_tasks') ?? true;
    weekStartsMonday = prefs.getBool('week_starts_monday') ?? false;
    confirmBeforeDelete = prefs.getBool('confirm_before_delete') ?? true;
    final savedThemeMode = prefs.getString('theme_mode');
    themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == savedThemeMode,
      orElse: () => ThemeMode.system,
    );
    final user = signedInUser;
    final raw = user == null
        ? prefs.getString('taskmate_tasks')
        : prefs.getString('taskmate_tasks_${user.uid}') ??
            prefs.getString('taskmate_tasks');
    if (raw != null) {
      try {
        tasks
            .addAll((jsonDecode(raw) as List).map((e) => TaskItem.fromJson(e)));
      } catch (_) {}
    } else if (user == null) {
      _seed();
      await _save();
    }
    if (user != null) {
      try {
        await _activateCloudAccount(user.uid);
      } catch (_) {}
      if (_cloudSubscription == null) _watchCloudTasks(user.uid);
    }
    loaded = true;
    notifyListeners();
  }

  void _seed() {
    final today = DateUtils.dateOnly(DateTime.now());
    tasks.addAll([
      TaskItem(
          id: 'demo1',
          title: 'Plan the week ahead',
          note: 'Review priorities and block focus time.',
          date: today,
          time: '09:00 AM',
          category: 'Work',
          priority: 2),
      TaskItem(
          id: 'demo2',
          title: 'Morning workout',
          note: 'A little movement goes a long way.',
          date: today,
          time: '07:30 AM',
          category: 'Health',
          priority: 1,
          done: true),
      TaskItem(
          id: 'demo3',
          title: 'Read 20 pages',
          date: today,
          time: '08:00 PM',
          category: 'Personal',
          priority: 1),
      TaskItem(
          id: 'demo4',
          title: 'Prepare project notes',
          date: today.add(const Duration(days: 1)),
          time: '11:00 AM',
          category: 'Work',
          priority: 2),
      TaskItem(
          id: 'demo5',
          title: 'Call the family',
          date: today.add(const Duration(days: 2)),
          time: '06:00 PM',
          category: 'Personal',
          priority: 0),
    ]);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final user = signedInUser;
    final key = user == null ? 'taskmate_tasks' : 'taskmate_tasks_${user.uid}';
    final saved = await prefs.setString(
      key,
      jsonEncode(tasks.map((task) => task.toJson()).toList()),
    );
    if (!saved) {
      throw StateError('Task data could not be saved to local storage.');
    }
  }

  List<TaskItem> get visibleTasks {
    final list = tasks
        .where((t) => DateUtils.isSameDay(t.date, selectedDate))
        .where((t) {
          if (filter == 'Pending') return !t.done;
          if (filter == 'Completed') return t.done;
          return true;
        })
        .where((t) => filter != 'All' || showCompletedTasks || !t.done)
        .where((t) =>
            t.title.toLowerCase().contains(query.toLowerCase()) ||
            t.category.toLowerCase().contains(query.toLowerCase()))
        .toList();
    list.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      return b.priority.compareTo(a.priority);
    });
    return list;
  }

  int get completed => tasks.where((t) => t.done).length;
  int get pending => tasks.where((t) => !t.done).length;
  double get progress => tasks.isEmpty ? 0 : completed / tasks.length;

  void selectDate(DateTime date) {
    selectedDate = DateUtils.dateOnly(date);
    focusedMonth = DateUtils.dateOnly(date);
    notifyListeners();
  }

  void changeMonth(int offset) {
    focusedMonth = DateTime(focusedMonth.year, focusedMonth.month + offset, 1);
    notifyListeners();
  }

  Future<void> add(TaskItem task) async {
    tasks.add(task);
    await _save();
    notifyListeners();
    await _saveCloudTask(task);
  }

  Future<void> update(TaskItem task) async {
    await _save();
    notifyListeners();
    await _saveCloudTask(task);
  }

  Future<void> delete(String id) async {
    tasks.removeWhere((t) => t.id == id);
    await _save();
    notifyListeners();
    final user = signedInUser;
    if (user != null) await _userTasks(user.uid).doc(id).delete();
  }

  Future<void> toggle(TaskItem task) async {
    task.done = !task.done;
    await _save();
    notifyListeners();
    await _saveCloudTask(task);
  }

  void setQuery(String v) {
    query = v;
    notifyListeners();
  }

  void setFilter(String v) {
    filter = v;
    notifyListeners();
  }

  Future<void> setShowCompletedTasks(bool value) async {
    showCompletedTasks = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_completed_tasks', value);
    notifyListeners();
  }

  Future<void> setWeekStartsMonday(bool value) async {
    weekStartsMonday = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('week_starts_monday', value);
    notifyListeners();
  }

  Future<void> setConfirmBeforeDelete(bool value) async {
    confirmBeforeDelete = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('confirm_before_delete', value);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
    notifyListeners();
  }

  Future<int> clearCompleted() async {
    final before = tasks.length;
    final removedIds =
        tasks.where((task) => task.done).map((task) => task.id).toList();
    tasks.removeWhere((t) => t.done);
    await _save();
    notifyListeners();
    final user = signedInUser;
    if (user != null) {
      for (final id in removedIds) {
        await _userTasks(user.uid).doc(id).delete();
      }
    }
    return before - tasks.length;
  }

  Future<void> signIn(String email, String password) async {
    final auth = _auth;
    if (auth == null) throw StateError('Firebase is not configured.');
    final credential = await auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await _activateCloudAccount(credential.user!.uid);
  }

  Future<void> createAccount(String email, String password) async {
    final auth = _auth;
    if (auth == null) throw StateError('Firebase is not configured.');
    final credential = await auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await _activateCloudAccount(credential.user!.uid);
  }

  Future<void> _activateCloudAccount(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final migrationKey = 'taskmate_cloud_migrated_$uid';
    final collection = _userTasks(uid);
    if (prefs.getBool(migrationKey) != true) {
      final remote = await collection.get();
      if (remote.docs.isEmpty) {
        for (final task in tasks) {
          await collection.doc(task.id).set(task.toJson());
        }
      } else {
        final remoteIds = remote.docs.map((doc) => doc.id).toSet();
        for (final task
            in tasks.where((task) => !remoteIds.contains(task.id))) {
          await collection.doc(task.id).set(task.toJson());
        }
      }
      await prefs.setBool(migrationKey, true);
    }
    await _loadCloudTasks(uid);
    _watchCloudTasks(uid);
    notifyListeners();
  }

  Future<void> _loadCloudTasks(String uid) async {
    final snapshot = await _userTasks(uid).get();
    tasks
      ..clear()
      ..addAll(snapshot.docs.map((doc) => TaskItem.fromJson(doc.data())));
    await _save();
  }

  void _watchCloudTasks(String uid) {
    _cloudSubscription?.cancel();
    _cloudSubscription = _userTasks(uid).snapshots().listen(
      (snapshot) async {
        tasks
          ..clear()
          ..addAll(snapshot.docs.map((doc) => TaskItem.fromJson(doc.data())));
        try {
          await _save();
        } catch (_) {}
        notifyListeners();
      },
      onError: (_) {},
    );
  }

  Future<void> _saveCloudTask(TaskItem task) async {
    final user = signedInUser;
    if (user != null) {
      await _userTasks(user.uid).doc(task.id).set(task.toJson());
    }
  }

  Future<void> signOut() async {
    await _cloudSubscription?.cancel();
    _cloudSubscription = null;
    await _auth?.signOut();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('taskmate_tasks');
    tasks
      ..clear()
      ..addAll(raw == null
          ? <TaskItem>[]
          : (jsonDecode(raw) as List).map((item) => TaskItem.fromJson(item)));
    notifyListeners();
  }

  @override
  void dispose() {
    _cloudSubscription?.cancel();
    super.dispose();
  }

  Future<void> resetPreferences() async {
    showCompletedTasks = true;
    weekStartsMonday = false;
    confirmBeforeDelete = true;
    themeMode = ThemeMode.system;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_completed_tasks', true);
    await prefs.setBool('week_starts_monday', false);
    await prefs.setBool('confirm_before_delete', true);
    await prefs.setString('theme_mode', ThemeMode.system.name);
    notifyListeners();
  }

  bool hasTasks(DateTime day) =>
      tasks.any((t) => DateUtils.isSameDay(t.date, day));
}

class TaskMateApp extends StatelessWidget {
  const TaskMateApp({super.key});
  @override
  Widget build(BuildContext context) {
    final themeMode = context.select<TaskStore, ThemeMode>(
      (store) => store.themeMode,
    );
    return MaterialApp(
      title: 'TaskMate',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        useMaterial3: true,
        scaffoldBackgroundColor: canvas,
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.dark,
        ),
      ),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int page = 0;
  final pages = const [DashboardPage(), InsightsPage(), SettingsPage()];
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      body: Row(children: [
        if (wide)
          _SideBar(selected: page, onSelect: (v) => setState(() => page = v)),
        Expanded(
            child: Column(children: [
          _TopBar(onAdd: () => showTaskEditor(context)),
          Expanded(child: IndexedStack(index: page, children: pages)),
        ])),
      ]),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (v) => setState(() => page = v),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.grid_view_rounded), label: 'Today'),
                NavigationDestination(
                    icon: Icon(Icons.insights_rounded), label: 'Insights'),
                NavigationDestination(
                    icon: Icon(Icons.tune_rounded), label: 'Settings'),
              ],
            ),
      floatingActionButton: wide
          ? null
          : FloatingActionButton(
              onPressed: () => showTaskEditor(context),
              backgroundColor: violet,
              foregroundColor: Colors.white,
              child: const Icon(Icons.add_rounded),
            ),
    );
  }
}

class _SideBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  const _SideBar({required this.selected, required this.onSelect});
  @override
  Widget build(BuildContext context) => Container(
        width: 238,
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(22, 28, 14, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: violet, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.check_rounded,
                    color: Colors.white, size: 23)),
            const SizedBox(width: 11),
            const Text('TaskMate',
                style: TextStyle(
                    fontSize: 21, fontWeight: FontWeight.w800, color: ink)),
          ]),
          const SizedBox(height: 48),
          const Text('WORKSPACE',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.5,
                  color: muted,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          _NavTile(
              icon: Icons.grid_view_rounded,
              label: 'My day',
              active: selected == 0,
              onTap: () => onSelect(0)),
          _NavTile(
              icon: Icons.insights_rounded,
              label: 'Insights',
              active: selected == 1,
              onTap: () => onSelect(1)),
          const SizedBox(height: 24),
          const Text('PREFERENCES',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.5,
                  color: muted,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          _NavTile(
              icon: Icons.tune_rounded,
              label: 'Settings',
              active: selected == 2,
              onTap: () => onSelect(2)),
          const Spacer(),
          Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                  color: const Color(0xFFF3F1FF),
                  borderRadius: BorderRadius.circular(16)),
              child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lightbulb_outline_rounded, color: violet),
                    SizedBox(height: 9),
                    Text('Small steps, big wins.',
                        style:
                            TextStyle(color: ink, fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text('Make today count.',
                        style: TextStyle(color: muted, fontSize: 12)),
                  ])),
        ]),
      );
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _NavTile(
      {required this.icon,
      required this.label,
      required this.active,
      required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              decoration: BoxDecoration(
                  color: active ? const Color(0xFFF0EEFF) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Icon(icon, size: 19, color: active ? violet : muted),
                const SizedBox(width: 12),
                Text(label,
                    style: TextStyle(
                        color: active ? violet : const Color(0xFF62677A),
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500))
              ])),
        ),
      );
}

class _TopBar extends StatelessWidget {
  final VoidCallback onAdd;
  const _TopBar({required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 78,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEFF0F5))),
      ),
      child: Row(
        children: [
          const Spacer(),
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2D2D3A) : const Color(0xFFF0EEFF),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              isDark ? Icons.nightlight_round : Icons.wb_sunny_outlined,
              color: isDark ? Colors.amberAccent : violet,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            DateFormat('EEE, d MMM').format(DateTime.now()),
            style: const TextStyle(color: muted, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 18),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New task'),
            style: FilledButton.styleFrom(
              backgroundColor: violet,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = context.watch<TaskStore>();
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 760;
    return SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 18 : 30),
        child: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1450),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_greeting(),
                        style: const TextStyle(color: muted, fontSize: 14)),
                    const SizedBox(height: 5),
                    const Text('Make room for what matters.',
                        style: TextStyle(
                            color: ink,
                            fontSize: 27,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.6)),
                    const SizedBox(height: 22),
                    _StatsRow(compact: compact),
                    const SizedBox(height: 24),
                    if (compact) ...[
                      _CalendarCard(),
                      const SizedBox(height: 18),
                      _TaskPanel(),
                    ] else
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 5, child: _TaskPanel()),
                            const SizedBox(width: 22),
                            Expanded(flex: 4, child: _CalendarCard()),
                          ]),
                    const SizedBox(height: 18),
                    if (store.tasks.isEmpty) const SizedBox.shrink(),
                  ])),
        ));
  }

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 12
        ? 'Good morning ☀️'
        : h < 17
            ? 'Good afternoon ✨'
            : 'Good evening 🌙';
  }
}

class _StatsRow extends StatelessWidget {
  final bool compact;
  const _StatsRow({required this.compact});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<TaskStore>();
    final items = [
      (
        'Total tasks',
        s.tasks.length.toString(),
        Icons.checklist_rounded,
        violet
      ),
      ('Completed', s.completed.toString(), Icons.task_alt_rounded, mint),
      (
        'In progress',
        s.pending.toString(),
        Icons.timelapse_rounded,
        const Color(0xFFE6A64C)
      ),
    ];
    return GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: compact ? 2 : 3,
        childAspectRatio: compact ? 1.8 : 2.35,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        children: items
            .map((e) => Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(color: const Color(0xFFEFF0F5))),
                  child: Row(children: [
                    Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                            color: e.$4.withValues(alpha: .11),
                            borderRadius: BorderRadius.circular(13)),
                        child: Icon(e.$3, color: e.$4, size: 21)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                          Text(e.$2,
                              style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: ink)),
                          Text(e.$1,
                              style:
                                  const TextStyle(fontSize: 12, color: muted),
                              overflow: TextOverflow.ellipsis),
                        ])),
                  ]),
                ))
            .toList());
  }
}

class _CalendarCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<TaskStore>();
    final first = DateTime(s.focusedMonth.year, s.focusedMonth.month, 1);
    final offset = s.weekStartsMonday ? first.weekday - 1 : first.weekday % 7;
    final days = DateTime(s.focusedMonth.year, s.focusedMonth.month + 1, 0).day;
    final cells = ((offset + days + 6) ~/ 7) * 7;
    return Container(
        padding: const EdgeInsets.all(21),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEFF0F5))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Your calendar',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: ink)),
            const Spacer(),
            IconButton(
                onPressed: () => s.changeMonth(-1),
                icon: const Icon(Icons.chevron_left_rounded, color: muted)),
            Text(DateFormat('MMMM yyyy').format(s.focusedMonth),
                style:
                    const TextStyle(fontWeight: FontWeight.w700, color: ink)),
            IconButton(
                onPressed: () => s.changeMonth(1),
                icon: const Icon(Icons.chevron_right_rounded, color: muted)),
          ]),
          const SizedBox(height: 14),
          Row(
              children: (s.weekStartsMonday
                      ? ['M', 'T', 'W', 'T', 'F', 'S', 'S']
                      : ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
                  .map((d) => Expanded(
                      child: Center(
                          child: Text(d,
                              style: const TextStyle(
                                  color: muted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)))))
                  .toList()),
          const SizedBox(height: 9),
          GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: cells,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7, mainAxisSpacing: 5, crossAxisSpacing: 4),
              itemBuilder: (context, i) {
                final day = i - offset + 1;
                if (day < 1 || day > days) return const SizedBox();
                final date =
                    DateTime(s.focusedMonth.year, s.focusedMonth.month, day);
                final selected = DateUtils.isSameDay(date, s.selectedDate);
                final today = DateUtils.isSameDay(date, DateTime.now());
                final marked = s.hasTasks(date);
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => s.selectDate(date),
                  child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      decoration: BoxDecoration(
                          color: selected
                              ? violet
                              : today
                                  ? const Color(0xFFF0EEFF)
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(12)),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$day',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: selected || today
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    color: selected ? Colors.white : ink)),
                            const SizedBox(height: 3),
                            Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                    color: marked
                                        ? (selected ? Colors.white : mint)
                                        : Colors.transparent,
                                    shape: BoxShape.circle)),
                          ])),
                );
              }),
          const SizedBox(height: 15),
          const Divider(color: Color(0xFFF0F1F5)),
          Row(children: [
            Container(
                width: 8,
                height: 8,
                decoration:
                    const BoxDecoration(color: mint, shape: BoxShape.circle)),
            const SizedBox(width: 7),
            const Text('Days with tasks',
                style: TextStyle(color: muted, fontSize: 11)),
            const Spacer(),
            Text('${s.tasks.length} scheduled',
                style: const TextStyle(
                    color: ink, fontWeight: FontWeight.w700, fontSize: 11))
          ]),
        ]));
  }
}

class _TaskPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<TaskStore>();
    final dateLabel = DateUtils.isSameDay(s.selectedDate, DateTime.now())
        ? 'Today'
        : DateFormat('EEEE, d MMM').format(s.selectedDate);
    return Container(
        padding: const EdgeInsets.all(21),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEFF0F5))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text('Daily plan',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: ink)),
                  const SizedBox(height: 4),
                  Text(dateLabel,
                      style: const TextStyle(color: muted, fontSize: 12)),
                ])),
            TextButton.icon(
                onPressed: () =>
                    showTaskEditor(context, initialDate: s.selectedDate),
                icon: const Icon(Icons.add, size: 17),
                label: const Text('Add task')),
          ]),
          const SizedBox(height: 15),
          TextField(
              onChanged: s.setQuery,
              decoration: const InputDecoration(
                  hintText: 'Search tasks...',
                  prefixIcon: Icon(Icons.search_rounded, size: 20),
                  isDense: true)),
          const SizedBox(height: 12),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                  children: ['All', 'Pending', 'Completed'].map((f) {
                final active = s.filter == f;
                return Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                        label: Text(f),
                        selected: active,
                        onSelected: (_) => s.setFilter(f),
                        selectedColor: const Color(0xFFEDEBFF),
                        backgroundColor: const Color(0xFFF7F7FA),
                        labelStyle: TextStyle(
                            color: active ? violet : muted,
                            fontWeight: FontWeight.w600,
                            fontSize: 12),
                        side: BorderSide.none));
              }).toList())),
          const SizedBox(height: 10),
          if (s.visibleTasks.isEmpty)
            _EmptyTasks(
                onAdd: () =>
                    showTaskEditor(context, initialDate: s.selectedDate))
          else
            ...s.visibleTasks
                .map((t) => _TaskTile(task: t, key: ValueKey(t.id))),
        ]));
  }
}

class _EmptyTasks extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyTasks({required this.onAdd});
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 35),
      child: Center(
          child: Column(children: [
        Container(
            width: 58,
            height: 58,
            decoration: const BoxDecoration(
                color: Color(0xFFF2F0FF), shape: BoxShape.circle),
            child:
                const Icon(Icons.event_note_rounded, color: violet, size: 27)),
        const SizedBox(height: 12),
        const Text('Nothing on your list',
            style: TextStyle(color: ink, fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        const Text('Enjoy the breathing room or add a task.',
            style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 12),
        TextButton(onPressed: onAdd, child: const Text('Create a task')),
      ])));
}

class _TaskTile extends StatelessWidget {
  final TaskItem task;
  const _TaskTile({required this.task, super.key});

  Future<void> _delete(BuildContext context) async {
    final store = context.read<TaskStore>();
    final messenger = ScaffoldMessenger.of(context);
    if (store.confirmBeforeDelete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete this task?'),
          content: Text('"${task.title}" will be permanently removed.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Keep task')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD95D68),
                  foregroundColor: Colors.white),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await store.delete(task.id);
    } catch (_) {
      if (context.mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Task removed locally, but cloud sync failed.'),
          ),
        );
      }
    }
  }

  Future<void> _toggle(BuildContext context) async {
    final store = context.read<TaskStore>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await store.toggle(task);
    } catch (_) {
      if (context.mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Task updated locally, but cloud sync failed.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = task.category == 'Work'
        ? violet
        : task.category == 'Health'
            ? mint
            : const Color(0xFFE4A34A);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: task.done ? const Color(0xFFFAFAFC) : Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFEDEEF4)),
      ),
      child: Row(children: [
        InkWell(
          onTap: () => _toggle(context),
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 23,
            height: 23,
            decoration: BoxDecoration(
              color: task.done ? mint : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                  color: task.done ? mint : const Color(0xFFD6D8E2),
                  width: 1.6),
            ),
            child: task.done
                ? const Icon(Icons.check, size: 15, color: Colors.white)
                : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: () => showTaskEditor(context, task: task),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(task.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: task.done ? muted : ink,
                    decoration: task.done ? TextDecoration.lineThrough : null,
                  )),
              if (task.note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(task.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 11)),
                ),
              const SizedBox(height: 7),
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(task.category,
                      style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                ),
                if (task.time.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.schedule_rounded, size: 12, color: muted),
                  const SizedBox(width: 3),
                  Text(task.time,
                      style: const TextStyle(color: muted, fontSize: 10)),
                ],
              ]),
            ]),
          ),
        ),
        const SizedBox(width: 7),
        _PriorityDot(priority: task.priority),
        PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.more_horiz, color: muted),
          onSelected: (v) {
            if (v == 'edit') showTaskEditor(context, task: task);
            if (v == 'delete') _delete(context);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit task')),
            PopupMenuItem(value: 'delete', child: Text('Delete task')),
          ],
        ),
      ]),
    );
  }
}

class _PriorityDot extends StatelessWidget {
  final int priority;
  const _PriorityDot({required this.priority});
  @override
  Widget build(BuildContext context) {
    final c = priority == 2
        ? const Color(0xFFE66D70)
        : priority == 1
            ? const Color(0xFFE6A64C)
            : mint;
    final label = priority == 2
        ? 'High'
        : priority == 1
            ? 'Medium'
            : 'Low';
    return Row(children: [
      Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700))
    ]);
  }
}

void showTaskEditor(BuildContext context,
    {TaskItem? task, DateTime? initialDate}) {
  showDialog(
      context: context,
      builder: (ctx) => TaskEditorDialog(task: task, initialDate: initialDate));
}

class TaskEditorDialog extends StatefulWidget {
  final TaskItem? task;
  final DateTime? initialDate;
  const TaskEditorDialog({super.key, this.task, this.initialDate});
  @override
  State<TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<TaskEditorDialog> {
  final form = GlobalKey<FormState>();
  late final TextEditingController title;
  late final TextEditingController note;
  late DateTime date;
  String category = 'Personal', time = '';
  int priority = 1;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final t = widget.task;
    title = TextEditingController(text: t?.title ?? '');
    note = TextEditingController(text: t?.note ?? '');
    date = t?.date ?? widget.initialDate ?? DateUtils.dateOnly(DateTime.now());
    category = t?.category ?? 'Personal';
    priority = t?.priority ?? 1;
    time = t?.time ?? '';
  }

  @override
  void dispose() {
    title.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: Text(widget.task == null ? 'Create a task' : 'Edit task',
              style: const TextStyle(color: ink, fontWeight: FontWeight.w800)),
          content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: SingleChildScrollView(
                  child: Form(
                      key: form,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextFormField(
                                controller: title,
                                autofocus: true,
                                decoration: const InputDecoration(
                                    labelText: 'Task title',
                                    hintText: 'What needs to get done?'),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? 'Please enter a task title'
                                    : null),
                            const SizedBox(height: 12),
                            TextField(
                                controller: note,
                                maxLines: 2,
                                decoration: const InputDecoration(
                                    labelText: 'Notes (optional)',
                                    hintText: 'Add a little detail')),
                            const SizedBox(height: 14),
                            const Text('Due date',
                                style: TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            OutlinedButton.icon(
                                onPressed: () async {
                                  final d = await showDatePicker(
                                      context: context,
                                      initialDate: date,
                                      firstDate: DateTime(2020),
                                      lastDate: DateTime(2100));
                                  if (d != null) setState(() => date = d);
                                },
                                icon: const Icon(Icons.calendar_today_outlined,
                                    size: 17),
                                label: Text(DateFormat('EEE, d MMM yyyy')
                                    .format(date))),
                            const SizedBox(height: 12),
                            const Text('Category',
                                style: TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            Wrap(
                                spacing: 7,
                                children: ['Personal', 'Work', 'Health']
                                    .map((c) => ChoiceChip(
                                        label: Text(c),
                                        selected: category == c,
                                        onSelected: (_) =>
                                            setState(() => category = c),
                                        selectedColor: const Color(0xFFEDEBFF),
                                        side: BorderSide.none,
                                        labelStyle: TextStyle(
                                            color: category == c
                                                ? violet
                                                : muted)))
                                    .toList()),
                            const SizedBox(height: 12),
                            const Text('Priority',
                                style: TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            SegmentedButton<int>(
                                segments: const [
                                  ButtonSegment(value: 0, label: Text('Low')),
                                  ButtonSegment(
                                      value: 1, label: Text('Medium')),
                                  ButtonSegment(value: 2, label: Text('High'))
                                ],
                                selected: {
                                  priority
                                },
                                onSelectionChanged: (v) =>
                                    setState(() => priority = v.first)),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                                onPressed: () async {
                                  final t = await showTimePicker(
                                      context: context,
                                      initialTime: TimeOfDay.now());
                                  if (t != null) {
                                    setState(() => time = t.format(context));
                                  }
                                },
                                icon: const Icon(Icons.access_time, size: 17),
                                label: Text(time.isEmpty ? 'Add time' : time)),
                          ])))),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!form.currentState!.validate()) return;
                        final store = context.read<TaskStore>();
                        final messenger = ScaffoldMessenger.of(context);
                        final navigator = Navigator.of(context);
                        final existing = widget.task;
                        setState(() => saving = true);
                        try {
                          if (existing == null) {
                            await store.add(TaskItem(
                                id: DateTime.now()
                                    .microsecondsSinceEpoch
                                    .toString(),
                                title: title.text.trim(),
                                note: note.text.trim(),
                                date: date,
                                time: time,
                                category: category,
                                priority: priority));
                          } else {
                            existing.title = title.text.trim();
                            existing.note = note.text.trim();
                            existing.date = date;
                            existing.time = time;
                            existing.category = category;
                            existing.priority = priority;
                            await store.update(existing);
                          }
                          if (!mounted) return;
                          navigator.pop();
                        } catch (_) {
                          if (mounted) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Could not save the task. Check local storage and try again.'),
                              ),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => saving = false);
                        }
                      },
                style: FilledButton.styleFrom(
                    backgroundColor: violet, foregroundColor: Colors.white),
                child: Text(saving
                    ? 'Saving...'
                    : widget.task == null
                        ? 'Create task'
                        : 'Save changes')),
          ]);
}

class InsightsPage extends StatelessWidget {
  const InsightsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<TaskStore>();
    final ratio = s.progress;
    return SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Your progress',
                          style: TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.w800,
                              color: ink)),
                      const SizedBox(height: 6),
                      const Text(
                          'A little consistency adds up. Here is your snapshot.',
                          style: TextStyle(color: muted)),
                      const SizedBox(height: 24),
                      Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border:
                                  Border.all(color: const Color(0xFFEFF0F5))),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Overall completion',
                                    style: TextStyle(
                                        color: ink,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 20),
                                Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text('${(ratio * 100).round()}%',
                                          style: const TextStyle(
                                              fontSize: 42,
                                              fontWeight: FontWeight.w800,
                                              color: violet)),
                                      const Padding(
                                          padding: EdgeInsets.only(
                                              bottom: 8, left: 8),
                                          child: Text('of all tasks completed',
                                              style: TextStyle(color: muted))),
                                    ]),
                                const SizedBox(height: 12),
                                ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: LinearProgressIndicator(
                                        value: ratio,
                                        minHeight: 11,
                                        backgroundColor:
                                            const Color(0xFFF0EFF8),
                                        color: violet)),
                                const SizedBox(height: 12),
                                Text(
                                    '${s.completed} completed · ${s.pending} still to go',
                                    style: const TextStyle(
                                        color: muted, fontSize: 12)),
                              ])),
                      const SizedBox(height: 18),
                      LayoutBuilder(
                          builder: (context, c) => GridView.count(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  crossAxisCount: c.maxWidth < 600 ? 1 : 2,
                                  childAspectRatio:
                                      c.maxWidth < 600 ? 3.2 : 2.5,
                                  crossAxisSpacing: 14,
                                  mainAxisSpacing: 14,
                                  children: [
                                    _InsightCard(
                                        title: 'Completed',
                                        value: '${s.completed}',
                                        subtitle: 'Tasks checked off',
                                        icon: Icons.task_alt_rounded,
                                        color: mint),
                                    _InsightCard(
                                        title: 'Pending',
                                        value: '${s.pending}',
                                        subtitle: 'Ready for your attention',
                                        icon: Icons.hourglass_bottom_rounded,
                                        color: const Color(0xFFE6A64C)),
                                  ])),
                      const SizedBox(height: 18),
                      Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(22),
                          decoration: BoxDecoration(
                              color: const Color(0xFFF0EEFF),
                              borderRadius: BorderRadius.circular(18)),
                          child: const Row(children: [
                            Icon(Icons.auto_awesome_rounded,
                                color: violet, size: 26),
                            SizedBox(width: 14),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text('Keep your momentum',
                                      style: TextStyle(
                                          color: ink,
                                          fontWeight: FontWeight.w800)),
                                  SizedBox(height: 4),
                                  Text(
                                      'Break big goals into small, clear actions. You are making progress every time you show up.',
                                      style: TextStyle(
                                          color: Color(0xFF77738F),
                                          fontSize: 12)),
                                ])),
                          ])),
                    ]))));
  }
}

class _InsightCard extends StatelessWidget {
  final String title, value, subtitle;
  final IconData icon;
  final Color color;
  const _InsightCard(
      {required this.title,
      required this.value,
      required this.subtitle,
      required this.icon,
      required this.color});
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFEFF0F5))),
      child: Row(children: [
        Container(
            width: 45,
            height: 45,
            decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: color)),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 23, fontWeight: FontWeight.w800, color: ink)),
          Text(title,
              style: const TextStyle(color: ink, fontWeight: FontWeight.w700)),
          Text(subtitle, style: const TextStyle(color: muted, fontSize: 11))
        ]),
      ]));
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _clearCompleted(BuildContext context) async {
    final store = context.read<TaskStore>();
    if (store.completed == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There are no completed tasks to clear.')),
      );
      return;
    }
    final count = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear completed tasks?'),
        content: Text(
            'This will permanently remove ${store.completed} completed task(s). Pending tasks will stay untouched.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD95D68),
                foregroundColor: Colors.white),
            child: const Text('Clear tasks'),
          ),
        ],
      ),
    );
    if (count == true && context.mounted) {
      final removed = await store.clearCompleted();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$removed completed task(s) cleared.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TaskStore>();
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 700;
    return SingleChildScrollView(
      padding: EdgeInsets.all(compact ? 18 : 30),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1050),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Settings',
                style: TextStyle(
                    fontSize: 27, fontWeight: FontWeight.w800, color: ink)),
            const SizedBox(height: 6),
            const Text('Make TaskMate work the way you plan your day.',
                style: TextStyle(color: muted)),
            const SizedBox(height: 25),
            _SettingsSection(
              icon: Icons.palette_outlined,
              title: 'Appearance',
              description: 'Choose your preferred color theme.',
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                        value: ThemeMode.system, label: Text('System')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ],
                  selected: {store.themeMode},
                  onSelectionChanged: (modes) {
                    if (modes.isNotEmpty) store.setThemeMode(modes.first);
                  },
                ),
              ),
            ),
            const SizedBox(height: 18),
            _SettingsSection(
              icon: Icons.tune_rounded,
              title: 'Planning preferences',
              description: 'Choose how your calendar and daily list behave.',
              child: Column(children: [
                _PreferenceTile(
                  icon: Icons.check_circle_outline_rounded,
                  title: 'Show completed tasks',
                  subtitle: 'Keep finished tasks visible in the daily list.',
                  value: store.showCompletedTasks,
                  onChanged: store.setShowCompletedTasks,
                ),
                const Divider(height: 1, indent: 52),
                _PreferenceTile(
                  icon: Icons.calendar_month_outlined,
                  title: 'Start week on Monday',
                  subtitle: 'Change the calendar to a Monday-first week.',
                  value: store.weekStartsMonday,
                  onChanged: store.setWeekStartsMonday,
                ),
                const Divider(height: 1, indent: 52),
                _PreferenceTile(
                  icon: Icons.delete_sweep_outlined,
                  title: 'Confirm before deleting',
                  subtitle: 'Ask before a task is permanently removed.',
                  value: store.confirmBeforeDelete,
                  onChanged: store.setConfirmBeforeDelete,
                ),
              ]),
            ),
            const SizedBox(height: 18),
            const _CloudSyncSection(),
            const SizedBox(height: 18),
            _SettingsSection(
              icon: Icons.storage_outlined,
              title: 'Task data',
              description:
                  'Review and maintain the tasks saved on this device.',
              child: Column(children: [
                _DataSummaryRow(
                    label: 'All tasks',
                    value: '${store.tasks.length}',
                    color: violet),
                const SizedBox(height: 12),
                _DataSummaryRow(
                    label: 'Completed',
                    value: '${store.completed}',
                    color: mint),
                const SizedBox(height: 12),
                _DataSummaryRow(
                    label: 'Pending',
                    value: '${store.pending}',
                    color: const Color(0xFFE6A64C)),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _clearCompleted(context),
                    icon:
                        const Icon(Icons.cleaning_services_outlined, size: 18),
                    label: const Text('Clear completed tasks'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFB34F5A),
                      side: const BorderSide(color: Color(0xFFF0D7DA)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Only completed items are removed. Your pending tasks and their dates remain unchanged.',
                  style: TextStyle(color: muted, fontSize: 11, height: 1.4),
                ),
              ]),
            ),
            const SizedBox(height: 18),
            _SettingsSection(
              icon: Icons.info_outline_rounded,
              title: 'About TaskMate',
              description:
                  'A focused daily planner built for clarity and consistency.',
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                            color: const Color(0xFFF0EEFF),
                            borderRadius: BorderRadius.circular(13)),
                        child: const Icon(Icons.check_rounded,
                            color: violet, size: 25),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text('TaskMate',
                                style: TextStyle(
                                    color: ink,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15)),
                            SizedBox(height: 3),
                            Text('Version 1.1.0 · Flutter application',
                                style: TextStyle(color: muted, fontSize: 11)),
                          ])),
                    ]),
                    const SizedBox(height: 14),
                    const Text(
                      'Planning preferences stay on this device. Tasks are stored locally until you sign in to a configured Firebase account, where they sync across your devices.',
                      style:
                          TextStyle(color: muted, fontSize: 12, height: 1.55),
                    ),
                    const SizedBox(height: 13),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          await store.resetPreferences();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Planning preferences restored to defaults.')),
                            );
                          }
                        },
                        icon: const Icon(Icons.restart_alt_rounded, size: 17),
                        label: const Text('Restore default preferences'),
                      ),
                    ),
                  ]),
            ),
            const SizedBox(height: 24),
            const Center(
                child: Text('Designed to help you focus on what matters.',
                    style: TextStyle(color: muted, fontSize: 11))),
          ]),
        ),
      ),
    );
  }
}

class _CloudSyncSection extends StatefulWidget {
  const _CloudSyncSection();

  @override
  State<_CloudSyncSection> createState() => _CloudSyncSectionState();
}

class _CloudSyncSectionState extends State<_CloudSyncSection> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool createAccount}) async {
    if (!_formKey.currentState!.validate()) return;
    final store = context.read<TaskStore>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (createAccount) {
        await store.createAccount(_email.text, _password.text);
      } else {
        await store.signIn(_email.text, _password.text);
      }
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(_messageFor(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _messageFor(Object error) {
    if (error is FirebaseAuthException) {
      return switch (error.code) {
        'email-already-in-use' => 'An account already uses this email.',
        'invalid-email' => 'Enter a valid email address.',
        'weak-password' => 'Choose a stronger password.',
        'user-not-found' ||
        'wrong-password' ||
        'invalid-credential' =>
          'Email or password is incorrect.',
        _ => error.message ?? 'Could not connect to your account.',
      };
    }
    if (error is FirebaseException) {
      return error.message ?? 'Cloud sync failed. Check your connection.';
    }
    return 'Could not connect. Check your Firebase setup and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<TaskStore>();
    final user = store.signedInUser;
    return _SettingsSection(
      icon: Icons.cloud_outlined,
      title: 'Cloud sync',
      description: 'Sync your tasks across devices with a Firebase account.',
      child: !store.cloudSyncAvailable
          ? const Text(
              'Firebase is not configured for this project yet. Run flutterfire configure, enable Email/Password sign-in in Firebase Authentication, and create a Firestore database.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.5),
            )
          : user != null
              ? Row(
                  children: [
                    const Icon(Icons.cloud_done_outlined, color: mint),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Syncing as ${user.email ?? user.uid}',
                        style: const TextStyle(
                            color: ink, fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Sign out',
                      onPressed: _busy
                          ? null
                          : () async {
                              await store.signOut();
                            },
                      icon: const Icon(Icons.logout_rounded),
                    ),
                  ],
                )
              : Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: (value) =>
                            value == null || !value.trim().contains('@')
                                ? 'Enter a valid email address.'
                                : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock_outline_rounded),
                        ),
                        validator: (value) => value == null || value.length < 6
                            ? 'Use at least 6 characters.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _submit(createAccount: false),
                              child: const Text('Sign in'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: _busy
                                  ? null
                                  : () => _submit(createAccount: true),
                              style: FilledButton.styleFrom(
                                  backgroundColor: violet,
                                  foregroundColor: Colors.white),
                              child: Text(
                                  _busy ? 'Connecting...' : 'Create account'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Widget child;
  const _SettingsSection(
      {required this.icon,
      required this.title,
      required this.description,
      required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: const Color(0xFFEDEEF4)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x080F172A), blurRadius: 18, offset: Offset(0, 5))
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 37,
              height: 37,
              decoration: BoxDecoration(
                  color: const Color(0xFFF0EEFF),
                  borderRadius: BorderRadius.circular(11)),
              child: Icon(icon, color: violet, size: 19),
            ),
            const SizedBox(width: 11),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: const TextStyle(
                          color: ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(description,
                      style: const TextStyle(color: muted, fontSize: 11)),
                ])),
          ]),
          const SizedBox(height: 18),
          child,
        ]),
      );
}

class _PreferenceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _PreferenceTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(children: [
          Icon(icon, color: muted, size: 20),
          const SizedBox(width: 13),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        color: ink, fontWeight: FontWeight.w700, fontSize: 12)),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: const TextStyle(
                        color: muted, fontSize: 11, height: 1.35)),
              ])),
          const SizedBox(width: 8),
          Switch.adaptive(
              value: value, onChanged: onChanged, activeColor: violet),
        ]),
      );
}

class _DataSummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _DataSummaryRow(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 9),
        Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: ink, fontSize: 12, fontWeight: FontWeight.w600))),
        Text(value,
            style: const TextStyle(
                color: ink, fontWeight: FontWeight.w800, fontSize: 13)),
      ]);
}
