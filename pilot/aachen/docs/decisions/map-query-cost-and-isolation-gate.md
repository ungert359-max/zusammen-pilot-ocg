# Architekturentscheidung: DB-Kosten- und Isolations-Gate für Karten-Erweiterungen

Status: VERBINDLICH FÜR DEN PILOTEN

## Entscheidung

**Wir bauen es so, dass es erst aktiviert werden darf, nachdem bewiesen wurde, dass die konkrete Abfrage billig ist, und dass es im Fehlerfall automatisch vom eigentlichen OCG-Kartenbetrieb isoliert werden kann.**

Diese Regel gilt für jede Aachen-spezifische Erweiterung, die zusätzliche Datenbankarbeit an den bestehenden Explore-/Map-Pfad hängt, insbesondere für Social-/Connection-Hinweise, Freunde-/Teilnehmer-Badges, zusätzliche Event-Metadaten, Matching- oder Personalisierungsinformationen sowie spätere Karten-Overlays.

Die normale OCG-Karte ist der geschützte Basispfad. Eine optionale Zusatzfunktion darf weder Voraussetzung für die Karte sein noch deren Verfügbarkeit gefährden.

## Verbindliches Aktivierungs-Gate

Eine solche Erweiterung bleibt standardmäßig **OFF**, bis alle folgenden Punkte nachweislich erfüllt sind:

1. **Konkreter Query-Plan geprüft.** Die tatsächlich eingesetzte SQL-Abfrage wird mit realistischen Pilotdaten über `EXPLAIN (ANALYZE, BUFFERS)` oder eine gleichwertige Messung geprüft.
2. **Kosten nachgewiesen.** Laufzeit, gelesene/berührte Datenmenge und Query-Plan liegen innerhalb eines vor Aktivierung festgelegten Pilotbudgets. Ein bloßes „sollte schnell sein“ reicht nicht.
3. **Indizes verifiziert.** Alle für Filter, Joins und Lookup-Pfade erforderlichen Indizes sind vorhanden und werden im gemessenen Plan sinnvoll genutzt.
4. **Abfrage hart begrenzt.** Zusatzabfragen arbeiten nur auf dem bereits begrenzten Ergebnissatz bzw. den konkreten Event-IDs des aktuellen Kartenaufrufs und dürfen keine ungebundene Vollsuche über Event-, Attendance-, Network- oder vergleichbare Tabellen auslösen.
5. **Kein N+1.** Pro Kartenaktualisierung ist nur eine begrenzte Batch-Abfrage für die jeweilige Zusatzinformation zulässig; keine zusätzliche Abfrage pro Event, Person, Connection oder Badge.
6. **Keine unnötige Arbeit.** Wenn die Zusatzinformation nicht benötigt werden kann, z. B. ohne eingeloggten Nutzer oder ohne relevante Connections, wird keine entsprechende Zusatzabfrage ausgeführt.
7. **Request-Flut begrenzt.** Kartenbewegungen dürfen nicht ungefiltert neue DB-Arbeit erzeugen. Debounce/Throttling und das Verwerfen veralteter Requests sind vorzusehen; identische teure Berechnungen können zusätzlich kurzzeitig gecacht werden.
8. **Kurzer, scoped Timeout.** Der Zusatzpfad erhält einen angemessenen eigenen Query-/Statement-Timeout. Ein Timeout oder Fehler beendet nur die Zusatzfunktion.
9. **Feature Flag / Kill-Switch vorhanden.** Die Erweiterung kann unabhängig vom OCG-Kern sofort deaktiviert werden.
10. **Graceful Degradation bewiesen.** Bei Fehler, Timeout, Überlastung oder deaktivierter Feature Flag wird lediglich das optionale Overlay/Badge/Enrichment weggelassen; Explore/Map liefert weiterhin die normale OCG-Antwort.
11. **Rollback/Disable getestet.** Der Abschaltpfad wird vor der ersten Aktivierung praktisch getestet.
12. **Lasttest bestanden.** Vor öffentlicher Aktivierung wird die Zusatzabfrage mit einer realistischen Parallelität und Datenmenge belastet. Dabei dürfen keine unvertretbaren Auswirkungen auf normale Karten- und Kernabfragen auftreten.

## Fail-Closed-Regel

Fehlt ein Nachweis oder überschreitet die gemessene Abfrage das definierte Budget, bleibt die Zusatzfunktion **OFF**. Es gibt keine Aktivierung auf Basis einer Annahme.

Wird nach Aktivierung eine unerwartete Kostensteigerung, erhöhte DB-Latenz, Timeout-Rate oder Beeinträchtigung des OCG-Kartenpfads beobachtet, wird die Zusatzfunktion über den Kill-Switch deaktiviert, während der Basispfad weiterläuft.

## Architekturprinzip

Die Abhängigkeit läuft nur in eine Richtung:

`OCG Explore/Map -> optionales, begrenztes Enrichment`

Nicht zulässig ist:

`OCG Explore/Map -> zwingendes Enrichment -> Karte funktioniert nur, wenn Enrichment funktioniert`

Damit bleibt die zusätzliche Funktion ein entfernbares Pilot-Modul und nicht Teil der Verfügbarkeitskette der OCG-Karte.

## Geltungsbereich

Diese Entscheidung gilt zusätzlich zu `INTEGRATION-POLICY.md` und `DEPLOYMENT-GATES.md`. Bei jeder späteren Karten- oder Discovery-Erweiterung ist dieses Gate erneut auf die **konkrete** Abfrage anzuwenden; ein früher bestandener Test ist kein Freifahrtschein für eine andere SQL-Abfrage oder ein anderes Datenvolumen.
