# GlowMap

**Twinkly-style control for cheap addressable fairy lights.** An iOS app (SwiftUI) that
maps every LED of a WS281x string with the phone camera and then drives shape-aware effects —
either computed on the phone (DDP, 30 fps) or uploaded into [WLED](https://kno.wled.ge) as a
2D `ledmap.json` so the ESP32 runs them autonomously.

- Camera mapping: flat (window, wall) and **tree** (four views, cone unwrap); outlier filter by wire
  continuity, neighbour fill, layout rotate/flip, tap-to-verify.
- WLED over Wi‑Fi: discovery, live preview (WebSocket), 16 curated 2D effects with baked palettes,
  scenes, effect constructor (stripes, gradient, spiral, rings, plasma, sparkles), scrolling text,
  schedule and playlists stored in the controller, strip length 100/200/custom.
- Legacy BLE stage for the stock `LEDDMX-00` controller (LED LAMP app family): colour, brightness,
  effects, pause, plus a full protocol write-up of what that firmware can and cannot do
  (`docs/PIXEL-TEST.md`).

Hardware used: 200-LED USB fairy string (JH-CLD-01), ESP32 DevKit with WLED 16.0.1 on GPIO18
through a 220 Ω resistor, powered from the board's USB‑C. See `docs/ESP32.md` for wiring and the
WLED pitfalls (2D addressing, frozen segments, direct mode before scanning).

The UI is in Russian. Requires Xcode 16+, iOS 17+, a physical iPhone (camera, Bluetooth, local
network). MIT licensed.

---

# Гирлянда — iOS-приложение для LEDDMX-00 (JH-CLD-01)

SwiftUI + CoreBluetooth. Управляет родным BLE-контроллером гирлянды через сервис `FFE0`,
характеристику `FFE1`. Протокол проверен на реальной гирлянде LEDDMX-00-698A (22.10.2026): цвет, включение,
выключение, аппаратная яркость и встроенные эффекты.

| Команда | Пакет |
|---|---|
| Цвет (RGB) | `7B FF 07 RR GG BB 00 FF BF` |
| Включить | `7B FF 04 03 FF FF FF FF BF` |
| Выключить | `7B FF 04 02 FF FF FF FF BF` |
| Яркость PP % | `7B FF 01 AA PP 00 FF FF BF`, AA = PP×32/100 |
| Эффект II (0…210) | `7B FF 03 II FF FF FF FF BF` |

## Требования

- Xcode 16 или новее (проект использует синхронизированные группы файлов).
- iOS 17.0+ (deployment target).
- Физический iPhone: в симуляторе CoreBluetooth недоступен, приложение покажет
  «Bluetooth LE недоступен» — это нормально.

## Запуск на iPhone

1. Открыть `Garland.xcodeproj`.
2. Выбрать target **Garland** → вкладка *Signing & Capabilities* → указать свою Team
   (Apple ID достаточно для личного устройства).
3. При необходимости поменять `Bundle Identifier` (`com.norgik.Garland`) на уникальный.
4. Подключить iPhone, выбрать его как destination, нажать ▶.
5. На телефоне разрешить Bluetooth при первом запросе.

Перед проверкой **закрыть LED LAMP и отключиться в nRF Connect** — контроллер держит одно
соединение.

## Тесты

```bash
xcodebuild test -project Garland.xcodeproj -scheme Garland -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

Тесты кодировщика подтверждают три проверенных пакета
(`7BFF07FF000000FFBF`, `7BFF0700FF0000FFBF`, `7BFF070000FF00FFBF`), длину 9 байтов,
порядок RGB и то, что пакет — бинарные байты, а не UTF-8 строка HEX.

## Структура

| Файл | Обязанность |
|---|---|
| `GarlandProtocol.swift` | Только формирование байтов пяти проверенных команд |
| `BluetoothManager.swift` | Поиск по имени `LEDDMX-00*`, подключение, обнаружение FFE0/FFE1, очередь записи, подписка на уведомления, журнал |
| `GarlandState.swift` | Фазы соединения, последние *запрошенные* параметры, записи журнала |
| `GarlandDevice.swift` | Найденное устройство, UUID-константы |
| `SavedColorsStore.swift` | Сцены (цвет + яркость) в UserDefaults |
| `ColorMath.swift` | HSV⇄RGB, колесо цвета |
| `EffectsSection.swift` | Перебор встроенных эффектов контроллера, пользовательские названия |
| `PhoneEffects.swift` | Эффекты, рассчитываемые телефоном (перелив, дыхание, свеча), и их цикл отправки |
| `PixelLabView.swift` | Лаборатория пикселей: ручная проверка непроверенных команд (конфигурация ленты, «защёлка», DIY-палитра, скорость, 2A-запрос) |
| `ContentView.swift` | Главный экран |
| `DevicePickerView.swift` | Список найденных гирлянд, переподключение, «забыть» |
| `DiagnosticsView.swift` | Журнал TX/RX, ручная HEX-команда, быстрые тесты команд протокола |

## Как устроена отправка

- Предпочтительно `.withoutResponse`; если характеристика его не объявит — `.withResponse`.
- Учитывается `canSendWriteWithoutResponse`, очередь возобновляется из
  `peripheralIsReady(toSendWriteWithoutResponse:)`.
- Потоки от колеса (цвет) и ползунка (яркость) хранятся как **одно последнее значение каждый**
  и уходят не чаще ~10 раз/с (стартовый параметр приложения, не предел контроллера).
  При отпускании — обязательная немедленная отправка последнего значения.
- Дискретные команды (питание, эффект, диагностика) идут отдельной FIFO-очередью с приоритетом.
- Если гирлянда выключена из приложения, выбор цвета/эффекта/сцены сначала шлёт «включить».
- «Готово к управлению» показывается только после обнаружения FFE1 с правом записи,
  не после `didConnect`.

## Яркость и эффекты

Яркость — аппаратная команда контроллера (0…100 %). Эффекты — встроенные анимации контроллера
(бегущие огни, переливы и т. п.) по индексу 0…210; они работают автономно, без телефона.
Контроллер не сообщает, что делает каждый индекс, поэтому названия пользователь задаёт сам
(долгое нажатие на плитку → «Переименовать»); они хранятся в UserDefaults. Сцена может
хранить либо цвет, либо эффект, плюс яркость.

## Живые эффекты (считает телефон)

«Перелив», «Дыхание» и «Свеча» рассчитываются в `PhoneEffectEngine` 20 раз в секунду и уходят
потоком обычных команд цвета (менеджер ограничивает его до ~10 Гц, лишние значения отбрасываются).
Ограничения честно показаны в интерфейсе: работают только пока приложение открыто и есть связь;
на время эффекта отключён автоблок экрана; сворачивание приложения останавливает эффект.
Эффект телефона и встроенный эффект контроллера взаимоисключающие — выбор одного останавливает
другой. Математика эффектов — чистые функции, покрытые тестами (`PhoneEffectTests`).

## Попиксельное управление — исследование

См. [docs/PIXEL-TEST.md](docs/PIXEL-TEST.md): разбор семи открытых реализаций, смысл
DIY-команд, гипотеза «защёлки» через конфигурацию числа пикселей и протокол физического теста.
Команды лежат в `GarlandProtocol.Experimental` и считаются непроверенными, пока не пройден тест.

## Финальная схема (с 24.10.2026): ESP32 + WLED, главный экран `HomeView`

Корень приложения — `HomeView`: питание, яркость, **живое превью** карты (WebSocket `/ws`,
`{"lv":true}`), 16 готовых эффектов с зашитыми палитрами (`CuratedEffect`), сцены (`LightSceneStore`),
конструктор (`Constructor.swift`, `ConstructorView`), «⋯»: расписание и плейлист (`ScheduleView`,
пресеты/таймеры WLED, NTP), бегущий текст (`TextEffectView`, fx 122), карта (скан, проверка,
поворот/отражение, загрузка в WLED), раздел «Разработчик» со старыми BLE-экранами.

Сканер умеет две формы: **плоская** (окно, стена) и **ёлка** — четыре ракурса с шагом 90°,
сшивка в развёртку конуса (`TreeScan.swift`): x — азимут вокруг ствола, y — высота;
невидимые ни с одной стороны LED координат не получают.

## Второй транспорт: ESP32 + WLED по Wi‑Fi (с 24.10.2026)

Гирлянда может работать от ESP32 с WLED (см. `docs/ESP32.md`). В приложении — иконка Wi‑Fi слева
вверху → экран **WLED**: поиск по Bonjour `_wled._tcp` или по IP, состояние, быстрые проверки
(сплошной цвет, пиксели 1·6·11), **сканирование камерой** и **карта с эффектами по форме**.

| Файл | Обязанность |
|---|---|
| `WLEDClient.swift` | HTTP JSON (`/json/info`, `/json/state`, `/json/cfg`) и DDP-поток кадров (UDP 4048) |
| `LEDMap.swift` | Карта `индекс → x,y` с уверенностью и флагом неоднозначности; хранение в Documents |
| `PixelScanner.swift` | Камера (AVFoundation), базовый кадр при погашенной ленте, по одному LED, разность кадров, центроид; `ScanMath` покрыт тестами |
| `ScanView.swift` | Подбор экспозиции, тестовый LED, запуск/остановка, результат и сохранение |
| `MapEffects.swift` | Эффекты по карте: проверка касанием, градиент, волна, рисование (30 fps по DDP) |
| `MapView.swift` | Карта: точки, касание → подсветка LED, настройки эффектов |

Разрешения: `NSLocalNetworkUsageDescription` + `NSBonjourServices` (локальная сеть), `NSCameraUsageDescription`.
Невидимые/неоднозначные LED координат не получают и в эффектах не участвуют — вымышленных точек нет.

## Обратная связь от контроллера

Приложение подписывается на уведомления FFE1 и читает её при подключении, но формат ответов
неизвестен — данные только журналируются в HEX. Интерфейс показывает «отправлено», а не
«подтверждено устройством».

## Чек-лист проверки на устройстве

Пройдено 22.10.2026 на iPhone 13: поиск `LEDDMX-00-698A`, FFE1 с `Read, Write,
WriteWithoutResponse, Notify`, три основных цвета, включение/выключение, яркость, эффекты.

Остаётся проверить при каждом изменении: быстрое движение по колесу не копит пакеты в журнале;
переподключение после пропадания питания; поведение при выключенном Bluetooth.

## Что сознательно НЕ обещано в этой версии

Управление отдельными светодиодами, загрузка собственных анимаций в контроллер, расписание,
фоновая работа. Команды скорости эффекта, таймера, микрофона и числа LED не исследованы —
их можно искать через «Произвольную команду» в диагностике.
