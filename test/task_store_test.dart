import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskmate/main.dart' as taskmate;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('task changes persist when the store is reloaded', () async {
    SharedPreferences.setMockInitialValues({});

    final store = taskmate.TaskStore();
    await store.load();
    final task = taskmate.TaskItem(
      id: 'persistence-test',
      title: 'Initial title',
      date: DateTime(2026, 11, 8),
    );

    await store.add(task);
    task.title = 'Updated title';
    await store.update(task);
    await store.toggle(task);

    final reloadedStore = taskmate.TaskStore();
    await reloadedStore.load();
    final savedTask = reloadedStore.tasks.singleWhere(
      (item) => item.id == task.id,
    );

    expect(savedTask.title, 'Updated title');
    expect(savedTask.done, isTrue);

    await reloadedStore.delete(task.id);
    final finalStore = taskmate.TaskStore();
    await finalStore.load();

    expect(finalStore.tasks.any((item) => item.id == task.id), isFalse);
  });
}
