# Architekturentscheidung: Altersgruppen über vorhandene OCG Event Category

Status: VERBINDLICH FÜR DEN PILOTEN

## Entscheidung

Für den Pilot `pilot-aachen-mvp` wird **kein neues Altersdatenmodell** eingeführt.

Die bereits vorhandene OCG-`Event Category` wird fachlich als **Altersgruppen-Taxonomie** verwendet. Die vorhandene `Group Category` bleibt die inhaltliche Einordnung der Gruppe bzw. Aktivität.

### Fachliche Zuordnung

**Group Category = Was?**

Beispiele:
- Sport
- Kultur
- Essen & Trinken
- Outdoor
- Spiele
- Bildung

**Event Category = Für welche Altersgruppe?**

Vorgesehene Werte:
- Alle Altersgruppen
- 18–25
- 26–35
- 36–50
- 51–65
- 65+

## Technische Leitlinie

Die bestehende OCG-Infrastruktur soll maximal wiederverwendet werden:

1. Beim Erstellen eines Events bleibt die vorhandene verpflichtende `event_category_id` bestehen.
2. Die sichtbare Bezeichnung `Event Category` wird im Pilot fachlich zu `Altersgruppe` umgeframed.
3. Die bereits vorhandenen OCG-Event-Kategorien werden mit den oben definierten Altersgruppen befüllt.
4. Der bereits vorhandene Explore-/Map-Filter für `event_category` wird als Altersgruppenfilter dargestellt.
5. Die bestehende serverseitige Filterlogik über `event_category` bleibt maßgeblich und wird wiederverwendet.
6. Es werden **kein Geburtsdatum und kein Nutzeralter** für diesen Mechanismus erhoben oder gespeichert.
7. Es werden **keine neue Tabelle, keine neue Spalte und keine neue Alters-Datenbankmigration** für diesen Mechanismus eingeführt.
8. Zusätzliche Eventdetails können weiterhin über vorhandene Tags laufen; Tags sind jedoch nicht der primäre Altersfilter.

## Sichtbarkeit auf Eventkarten

Auf Eventkarten soll die Altersgruppe möglichst direkt sichtbar werden, z. B.:

`Volleyball · 26–35`

Falls die kompakte `EventSummary` den Namen der Event Category dafür noch nicht mitliefert, darf als isolierte Mini-Erweiterung `event_category_name` in die bestehende Event-Zusammenfassung aufgenommen und für die Anzeige verwendet werden.

Diese Mini-Erweiterung darf **keine Schemaänderung und keine neue Datenbankmigration** auslösen; sie soll lediglich einen ohnehin bereits gespeicherten Wert zusätzlich ausgeben.

## Sicherheits-/Änderungsprinzip

Oberste Priorität bleibt die fehlerarme, additive Erweiterung des bestehenden OCG-Piloten:

- bestehende OCG-Mechanismen wiederverwenden statt neue parallele Systeme bauen;
- keine Nutzer-Altersdaten einführen, solange sie nicht zwingend erforderlich sind;
- keine Datenbankschemaänderung für den Altersgruppenmechanismus;
- vorhandene Filter-, Validierungs- und Suchpfade möglichst unverändert weiterverwenden;
- Änderungen an Darstellung/Benennung strikt von der bestehenden Kernlogik trennen.

## Nicht Bestandteil dieser Entscheidung

Diese Entscheidung führt **kein automatisches Matching nach dem tatsächlichen Alter eines Nutzers** ein. Der Filter bezieht sich ausschließlich auf die vom Event festgelegte Ziel-Altersgruppe.

Wenn später ein echtes Nutzeralter-Matching erforderlich wird, ist dafür eine separate Architektur- und Datenschutzentscheidung nötig.