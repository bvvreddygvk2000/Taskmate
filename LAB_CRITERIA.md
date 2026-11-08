# Lab criteria mapping

| Lab requirement | TaskMate implementation |
|---|---|
| Different widgets | Container, Row, Column, Stack-ready layouts, GridView, ListView-like task composition, Cards, buttons, chips, dialogs, progress indicators |
| Responsive UI | MediaQuery + LayoutBuilder; desktop sidebar, compact navigation bar, adaptive two-column/stacked dashboard |
| Navigation | Three destinations: My day, Insights, Settings; IndexedStack preserves page state |
| Animations | AnimatedContainer for task completion/calendar selection; transitions via Material interactions |
| State management | ChangeNotifier + Provider |
| Themes/custom widgets | Material 3 theme, reusable sidebar, navigation tiles, stats, calendar, task tile, priority and insight widgets |
| Forms/validation | Task editor form validates required title; date/time/category/priority inputs |
| Working functionality | CRUD, completion toggle, date selection, search, filters, statistics, local persistence and functional settings (calendar week start, completed visibility, delete confirmation and task cleanup) |
