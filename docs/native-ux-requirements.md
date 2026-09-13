# Natywny UX T2S+ — funkcje, które muszą zostać zachowane

Przegląd kodu Swift/AppKit z 12 września 2026. Ten dokument jest podstawą dalszego projektu natywnego interfejsu. Wcześniejsza makieta HTML nie jest specyfikacją kompletności i nie jest implementacją aplikacji.

**Warunek użytkownika: wszystkie istniejące funkcje pozostają dostępne, włącznie z wykresami rysowanymi na obrazie.** Tryby pracy organizują istniejące narzędzia. Nie ograniczają możliwości pomiaru, zapisu ani publikowania obrazu.

## Inwentaryzacja i dostęp w nowym oknie

| Obecna funkcja | Zachowanie do zachowania | Dostęp w natywnym UX |
| --- | --- | --- |
| Punkt | Kliknięcie dodaje pomiar średniej 3 × 3 piksele. | Narzędzia pomiarowe i obecny gest. |
| Obszar | Prostokąt, min/średnia/max oraz położenie najcieplejszego i najchłodniejszego piksela. | Narzędzia pomiarowe; tabela i oznaczenia na obrazie. |
| Linia | Końce linii, min/średnia/mediana/max, wskazanie wybranej liczby charakterystycznych punktów. | Narzędzia i szczegóły zaznaczonej linii. |
| Analiza linii | Liczba znaczników oraz tryby hot, cold, avg, med; ekstrema lub przecięcia średniej/mediany. | Widoczne ustawienia linii, bez usuwania któregokolwiek trybu. |
| Gest Shift | Odwrócenie narzędzia przeciągania: obszar ↔ linia. | Zachowany skrót gestu z opisem. |
| Lista pomiarów | Wybór obiektu, kolumny nazwa/min/avg/max/emisyjność; wybór pozostaje podczas aktualizacji. | Stały panel pomiarów. |
| Usuwanie | Usuń zaznaczony i usuń wszystkie. | Panel pomiarów. |
| Emisyjność | Osobna wartość dla obiektu; puste pole oznacza wartość globalną. | Szczegóły zaznaczonego pomiaru. |
| Śledzenie | Przyklejenie punktu, obszaru lub linii do fragmentu sceny. | Przycisk przy zaznaczonym obiekcie i stan w tabeli/na obrazie. |
| Utrata śledzenia | Pomarańczowe oznaczenie, linia przerywana, komunikat `track lost`; zachowanie pozycji i próba odzyskania. Odmowa śledzenia fragmentu bez kontrastu. | Zachowane oznaczenia i komunikaty; brak fałszywego stanu sukcesu. |
| Zatrzymanie śledzenia | Odpięcie wybranego obiektu i zatrzymanie śledzenia wszystkich. | Panel pomiarów. |
| Palety | Ironbow, White Hot, Black Hot, Rainbow, Hot, Inferno. | Widoczny wybór wszystkich sześciu palet. |
| Skala kolorów | Auto i ręczna, dolna/górna granica °C, legenda kolorów zgodna z zakresem skali. | Pasek obrazu. |
| Znaczniki | Niezależne Max, Min, Centre; widoczność powiązana z seriami wykresu i kolumnami logu. | Trzy niezależne przełączniki przy obrazie. |
| Wykresy | Wyłączone, nad obrazem, pod obrazem, bezpośrednio na obrazie obok pomiarów. | Widoczny wybór `Wykresy: Wył. / Nad / Pod / Na obrazie`. |
| Historia | Dwie minuty historii; wiele serii, kolory i automatyczna skala. Punkty własna średnia; obszary i linie średnia. | Zachowany wspólny model historii dla panelu i wykresów na obrazie. |
| Progi temperatur | Wyróżnianie powyżej i poniżej zadanej temperatury; oba progi niezależne, puste pole wyłącza próg. | Pasek obrazu lub stała sekcja progów. |
| Wykrywanie zmian | Nowe cieplejsze/chłodniejsze obszary względem adaptacyjnego odniesienia, próg Δ°C, odrębne kontury i etykiety. | Widoczny przełącznik i pole Δ°C. |
| Obrót | W lewo, w prawo i reset; prawidłowe współrzędne pomiarów i kliknięć oraz proporcje obrazu. | Narzędzia obrazu. |
| Zdjęcie | PNG z renderowanego obrazu; opcjonalna pełna macierz temperatur CSV. | Stała sekcja zapisu, przycisk zdjęcia i przełącznik macierzy. |
| Film | H.264 MOV z renderowanego obrazu, czas rzeczywisty klatek, rozpoczęcie/zakończenie. | Stała sekcja zapisu i widoczny stan nagrywania. |
| Timelapse | Odstęp w sekundach, czas trwania w minutach, PNG z opcjonalnymi macierzami CSV, licznik zdjęć i czas pozostały, stop. | Stała sekcja zapisu. |
| Log CSV | Osobny odstęp próbkowania, znaczniki i obiekty; punkt jako jedna wartość, obszar/linia min/avg/max; czas i licznik wierszy. | Stała sekcja zapisu. |
| Kolumny logu | Ustalane przy starcie; nowy pomiar nie zmienia nagłówka trwającego pliku. | Czytelna informacja o zakresie bieżącego logu. |
| Folder zapisu | Otwarcie katalogu wynikowego i komunikaty sukcesu/błędu. | Przycisk folderu w sekcji zapisu. |
| Wskaźniki sesji | REC, TIMELAPSE i LOG także w renderowanym obrazie. | Zachowane w rendererze; dodatkowo czytelne stany przy przyciskach. |
| NUC | Korekcja niejednorodności i obsługa martwych pikseli; osobna od kalibracji temperatury. | Własny przycisk i stan operacji. |
| Kalibracja °C | Jedno odniesienie, dwa odniesienia, reset dla bieżącego zakresu; zachowanie zapisanych parametrów i walidacji próbek. | Widoczna sekcja kalibracji z dostępem do wszystkich trzech operacji. |
| Zakres sprzętowy | Normalny −20…120 °C i wysoki −20…450 °C, osobne parametry kalibracji i komunikaty o weryfikacji. | Sekcja kamery; oddzielnie od skali kolorów. |
| Kamera wirtualna | Publikowanie renderowanego obrazu, włączenie/wyłączenie, status; instalowanie/zarządzanie rozszerzeniem. | Sekcja udostępniania i przycisk zarządzania rozszerzeniem. |
| macOS | Skróty, menu, konfigurowalny pasek narzędzi, skalowanie okna bez rozciągania obrazu, informacje o aplikacji i licencjach. | Zachowane elementy natywne AppKit; nowe przyciski wywołują te same akcje. |

## Wykres na obrazie jest częścią wyniku

Obecny przebieg w kodzie:

1. `ThermalViewController` zbiera historię pomiarów w `TemperatureHistory`.
2. Dla `chartPosition == .inline` przekazuje ostatnie, próbkowane wartości jako `ThermalRenderer.Frame.histories`.
3. `ThermalRenderer` rysuje małe wykresy obok punktów i obszarów w końcowym `CGImage`.
4. Ten obraz jest podglądem, źródłem PNG i timelapse, klatką filmu oraz klatką publikowaną do kamery wirtualnej.

**Nowy interfejs musi zachować ten przebieg.** Zastąpienie wykresów wyłącznie widokiem AppKit nałożonym na podgląd zgubiłoby je w zapisach i transmisji.

| Miejsce wykresu | Podgląd aplikacji | PNG / timelapse / MOV / kamera wirtualna |
| --- | --- | --- |
| Nad lub pod obrazem | Tak, osobny `ChartView`. | Obecnie ten panel nie jest częścią renderowanej klatki. |
| Na obrazie | Tak, część obrazu. | Tak, ten sam wyrenderowany wykres. |

Szczegół ustalony podczas przeglądu: historia jest zbierana również dla linii, ale obecna funkcja `drawLine` nie wywołuje `sparkline`. Miniwykresy na obrazie są aktualnie rysowane dla punktów i obszarów; linie mają swoje odczyty i znaczniki profilu oraz serie w osobnym wykresie. Dodanie miniwykresu przy linii byłoby rozszerzeniem, nie odtworzeniem już działającej funkcji.

## Zasady zmiany trybu pracy

- Tryb zmienia rozmieszczenie i nacisk na narzędzia, a nie model pomiaru.
- Wybrany sposób wyświetlania wykresów pozostaje zachowany po zmianie trybu. Tryb nie wyłącza samoczynnie wykresów na obrazie.
- Obiekty, ich emisyjność, przyklejenie i historia pozostają zachowane.
- Film, timelapse, log i publikowanie do kamery wirtualnej trwają nadal; zmiana trybu nie wywołuje ich ponownej inicjalizacji.
- Tryb nie zmienia samoczynnie zakresu sprzętowego, kalibracji, progów ani ręcznej skali kolorów.
- Wszystkie istniejące operacje mają dostęp w oknie. Menu i skróty pozostają drugim sposobem wykonania tych samych akcji.

## Rozszerzenia zamówione obok zachowania obecnych funkcji

| Rozszerzenie | Stan aktualnego kodu | Wymaganie dla dalszego wdrożenia |
| --- | --- | --- |
| Macierze temperatur razem z filmem | `Recorder.appendVideoFrame` otrzymuje tylko obraz. Obecne CSV zdjęć i log pomiarów nie są macierzami każdej klatki filmu. | Wspólna tożsamość i czas klatki obrazu oraz temperatur; określona orientacja, obsługa pominiętych klatek i błędów zapisu. |
| Nakładanie zwykłego obrazu i termowizji | Nie jest obecnie zaimplementowane jako drugi strumień w tym kontrolerze. | Natywny tryb beta dwóch kamer z wyborem źródeł i dopasowaniem przestrzennym. Pomiary pozostają w układzie sensora termicznego. |
| Synchronizacja dwóch kamer | Brak obecnego modułu parowania dwóch strumieni. | Osobne ustawienia dopasowania czasowego i przestrzennego; różnica czasów klatek oraz stan parowania. Sama zgodność konturów nie potwierdza zgodności czasu. |

To rozszerzenia implementacji Swift, nie funkcje uznane za gotowe na podstawie makiety. Tryb beta musi zachować nakładki pomiarów i wykresy w końcowym obrazie przeznaczonym do zapisu i udostępniania.

## Punkty odniesienia w kodzie

- [Menu i pełny zestaw akcji](../camera_extension/T2SCameraApp/AppDelegate.swift)
- [Pasek narzędzi](../camera_extension/T2SCameraApp/Toolbar.swift)
- [Stan interfejsu, przetwarzanie, pomiary, zapis](../camera_extension/T2SCameraApp/ThermalViewController.swift)
- [Renderer, nakładki i miniwykresy](../camera_extension/T2SCameraApp/ThermalRenderer.swift)
- [Wykres panelowy](../camera_extension/T2SCameraApp/ChartView.swift) i [historia](../camera_extension/T2SCameraApp/TemperatureHistory.swift)
- [Zapis obrazu i CSV](../camera_extension/T2SCameraApp/Recorder.swift)
- [Pomiary](../camera_extension/T2SCameraApp/Measurements.swift), [śledzenie](../camera_extension/T2SCameraApp/ObjectTracker.swift), [obsługa gestów](../camera_extension/T2SCameraApp/ThermalImageView.swift)
- [Palety](../camera_extension/T2SCameraApp/Palettes.swift) i [kalibracja](../camera_extension/T2SCameraApp/Calibration.swift)

## Warunki odbioru przebudowy

To lista przyszłej weryfikacji wdrożenia, nie raport z wykonanych testów aplikacji:

- Sprawdzić każdy wiersz inwentaryzacji w natywnym oknie i przez zachowane skróty.
- Uruchomić wykresy na obrazie, wykonać PNG, timelapse i film oraz sprawdzić odbiornik kamery wirtualnej: miniwykresy i odczyty muszą być obecne.
- Sprawdzić wszystkie cztery ustawienia wykresów i zachowanie wyboru między trybami.
- W trakcie filmu, timelapse i logu zmieniać tryby; sesje i ich stany muszą pozostać spójne.
- Obrócić obraz, zmienić rozmiar okna i śledzić punkt/obszar/linię przy ruchu kamery; zweryfikować położenie pomiarów i stan utraty śledzenia.
- Porównać wyniki pomiarów i CSV przed/po przebudowie na tych samych danych wejściowych oraz wykonać istniejące testy radiometrii.

Ten przegląd nie zmienia kodu aplikacji, algorytmu temperatur ani wydania.
