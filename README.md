# Subzero

Kill switch для программ на macOS. Если внешний IP не из разрешённых стран (упал VPN, сменилась сеть, утечка IPv6), выбранные программы замораживаются (`SIGSTOP`). Когда IP снова правильный, они оживают (`SIGCONT`). Если разрешённый IP не вернулся за заданное время, программы закрываются (`SIGKILL`).

Swift 6, SwiftUI, macOS 15+. Приложение есть и в Dock, и в строке меню. Оформлено как аркадный файтинг: пиксельный ледяной голем Frost (оригинальный персонаж), полоски «здоровья» IP и DNS, таймер раунда до закрытия программ, баннеры FIGHT! / FROZEN! / K.O.

- **Ледяной шар:** когда программа замерзает (автоматически или кнопкой ❄︎), голем бросает шар через арену, и иконка программы вмерзает в лёд. При закрытии (`SIGKILL`) лёд разлетается красными осколками с надписью K.O.
- **Строка меню:** пиксельная голова голема со статусом и, на выбор, флаг со страной или IP-адрес рядом с ним (Настройки → Поведение → Вид).
- **Dock:** клик по значку открывает настройки, правый клик даёт статус, «Проверить IP», паузу. Красный бейдж показывает, сколько программ заморожено. Значок можно убрать из Dock в настройках.

## Установка

```bash
brew tap igor-bite/tap
brew trust igor-bite/tap
brew install --cask subzero
```

Свежий Homebrew загружает casks из сторонних tap только после `brew trust`. Приложение подписано Developer ID и нотаризовано Apple, поддерживает macOS 15+ и Apple Silicon + Intel.

## Сборка и запуск

```bash
Scripts/compile_and_run.sh          # собрать Subzero.app, перезапустить, проверить, что живо
Scripts/compile_and_run.sh --test   # то же, но сначала тесты
swift test                          # только тесты
```

`Subzero.app` появляется в корне репозитория. Чтобы установить приложение, перенесите его в `/Applications`.

Иконка (`Icon.icns`) рисуется из того же спрайта голема: `Scripts/make_icon.sh`.

Релиз для Homebrew-tap: `Scripts/release.sh <версия>` (см. комментарий в начале скрипта).

## Как устроено

Пакет разбит на слои. Каждый зависит только от слоёв выше:

```
SubzeroCore    чистые модели и решения, без побочных эффектов
   ↑
SubzeroSystem  адаптеры macOS: сеть, процессы, сон, файл настроек
   ↑
SubzeroEngine  оркестратор GuardEngine без UI
   ↑
Subzero        приложение (SwiftUI/AppKit), в публичный API не входит
```

| Модуль | Файлы | Что |
|---|---|---|
| `SubzeroCore` | `Policy.swift` | Консенсус сервисов, вердикт (fail-closed), утечки IPv6/DNS, таймер «заморозить → закрыть» (`Enforcer`) |
| | `IPAddress.swift` | IPv4/IPv6 и CIDR |
| | `Processes.swift` | Модель процесса, дерево, сопоставление с правилами и потомки |
| | `Config.swift` | `GuardConfig`, `AppRule`, страны |
| `SubzeroSystem` | `IPProbe.swift` | IPv4 у 4 сервисов, IPv6 у 3, страна через ipinfo.io → country.is → ipapi.co, DNS через `whoami.akamai.net` |
| | `ProcessScanner.swift` | Список процессов (`sysctl`), сигналы |
| | `NetworkChangeMonitor.swift`, `SleepWakeMonitor.swift` | Смена сети (`NWPathMonitor`), сон и пробуждение |
| | `ConfigStore.swift` | JSON с настройками на диске |
| `SubzeroEngine` | `GuardEngine.swift` | Цикл проверок, пауза, ручная заморозка, применение сигналов, события `GuardEvent` |
| | `Dependencies.swift` | Протоколы `NetworkProbing` и `ProcessControlling` для подмены системы |
| `Subzero` | `*View.swift`, `Arcade.swift` | Меню, настройки, аркадная дизайн-система |
| | `EngineBridge.swift`, `Texts.swift` | Уведомления, бейдж Dock, русские тексты для событий и причин блокировки |

Настройки хранятся в `~/Library/Application Support/Subzero/config.json`.

## Подключение как библиотеки (SwiftPM)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Igor-bite/subzero.git", from: "0.3.0"),
],
targets: [
    .target(name: "MyTool", dependencies: [
        .product(name: "SubzeroEngine", package: "subzero"),
    ]),
]
```

Продукты:

- **`SubzeroCore`** — только логика: вердикт по снимку сети, сопоставление процессов с правилами. Без сети и сигналов, удобно для тестов и своих движков.
- **`SubzeroSystem`** — реальные адаптеры macOS поверх Core.
- **`SubzeroEngine`** — готовый движок целиком.

Чистое решение без побочных эффектов:

```swift
import SubzeroCore

let ip = IPAddress("185.10.10.10")!
let snapshot = NetworkSnapshot(ipv4: .agreed(ip, votes: 3), ipv6: .none, countries: [ip: "NL"])
let verdict = evaluate(
    snapshot,
    rules: AllowRules(countries: ["NL", "DE"], networks: ["10.0.0.0/8"]),
    settings: PolicySettings(minAgree: 2, checkIPv6: true, blockWhenOffline: true)
)
// .allowed(185.10.10.10)
```

Движок целиком:

```swift
import SubzeroCore
import SubzeroEngine
import SubzeroSystem

@MainActor
func run() {
    let engine = GuardEngine(store: ConfigStore(url: myConfigURL))
    engine.config.allowedCountries = ["NL"]
    engine.config.apps = [AppRule(name: "Cursor", kind: .bundle(path: "/Applications/Cursor.app"))]
    engine.onEvent = { event in print(event) }   // .blocked, .resumed, .killed, .pauseEnded, .dnsWarning
    engine.start()
    // При выходе обязательно: размораживает всё, что остановил движок.
    // engine.shutdown()
}
```

`GuardEngine` — `@MainActor @Observable`: состояние (`phase`, `controlledApps`, `snapshot`, `killDeadline`…) можно напрямую показывать в SwiftUI. Для тестов подставьте свои `NetworkProbing` и `ProcessControlling` и `observesSystem: false` (пример в `Tests/SubzeroEngineTests`).

Важно: движок fail-closed. Пока нет первого вердикта, защищённые программы заморожены; `shutdown()` нужно вызывать при любом выходе хоста (включая `SIGTERM`), иначе программы останутся остановленными.

## Поведение

- **Пока нет подтверждённого IP, программы заморожены:** при старте, после смены сети, после пробуждения, при расхождении сервисов.
- **Сон.** Перед сном программы замораживаются, после пробуждения отпускаются только после проверки IP.
- **Выход из Subzero** (меню, `SIGTERM`, выход из системы) размораживает всё.
- **Если Subzero упал,** программы остаются замороженными. Это fail-closed. При следующем запуске и разрешённом IP Subzero их отпустит.
- **Safari защитить нельзя:** его вкладки работают в общих системных процессах.

## Утечка DNS

Subzero спрашивает `whoami.akamai.net` через системный резолвер (как это делают сами программы). Ответ — адрес, с которого DNS-резолвер ходит в интернет. Утечкой считается случай, когда страна этого адреса не входит в разрешённые и не совпадает со страной внешнего IP. Обычно так бывает, если трафик идёт через VPN, а DNS остался у провайдера.

Действия (Настройки → Поведение → «Утечка DNS»): игнорировать, предупреждать, замораживать (затем закрыть по общему таймеру), убивать сразу.

- **Остальные страны** — действие по умолчанию (по умолчанию «предупреждать»).
- **Правило для страны** — своё действие, когда резолвер в этой стране. Срабатывает даже для разрешённой страны; резолвер в стране внешнего IP утечкой не считается никогда. Например: RU → «убивать сразу», US → «игнорировать», остальные → «предупреждать».

Если страну резолвера определить не удалось, утечкой это не считается.

## Ручное управление

В меню и в настройках у каждой программы есть кнопки:

- **❄︎ Заморозить:** программа стоит при любом IP, пока её не разморозить. Ручная заморозка переживает перезапуск Subzero. При выходе из Subzero программа размораживается, а при следующем запуске снова замерзает.
- **▶︎ Разморозить:** снимает ручную заморозку. Если программа заморожена из-за чужого IP, она работает до конца блокировки (бейдж «отпущено»).
- **✕ Убить:** немедленный `SIGKILL` всем процессам программы, с подтверждением.

Кнопка «+ Заморозить» в меню замораживает любую запущенную программу, даже если её нет в списке защиты.

## Снимки UI (debug)

```bash
swift build && "$(swift build --show-bin-path)/Subzero" --render-snapshots /tmp/subzero-shots
```

Команда рисует меню (включая кадры броска ледяного шара) и вкладки настроек на тестовых данных (светлая и тёмная тема) в PNG. Проверки и сигналы при этом не запускаются.
