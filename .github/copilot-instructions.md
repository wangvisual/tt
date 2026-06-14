# Copilot Instructions

## Stack

- **Backend**: Perl CGI (`tt.pl`), Perl 5.22, Apache HTTPD
- **Frontend**: ExtJS 3.4 (`tt.js`) + jQuery (for bracket view)
- **Database**: SQLite via `db.pm` wrapper (`db/pewebmgr.db`)
- **Schema migrations**: `db.pm` `upgrade_db()` — increments `PRAGMA user_version`; current version is 3

## Key Files

| File | Purpose |
|------|---------|
| `tt.pl` | All backend CGI actions; dispatched via `@valid_actions` list at bottom |
| `tt.js` | All ExtJS UI — grids, forms, windows, toolbar handlers |
| `db.pm` | SQLite wrapper; `init_db` + `upgrade_db`; `exec(sql, params, mode)` |
| `settings.pm` / `site_settings.pm` | LDAP, mail, title config |
| `etc/` | Avatar images and icons |

## Architecture

- Every browser request POSTs `action=<name>` to `tt.pl`; the action must be in `@valid_actions`
- `db->exec(sql, \@params, $mode)`: mode 0 = write, 1 = read (returns array of hashrefs), 2 = insert (sets `last_insert_id`)
- All timestamps stored as UTC via SQLite `datetime('now')`. Frontend converts to local time using `utcToLocal()` in `tt.js`
- `getUserList` returns `full_name` = `name || ", " || cn_name || ", " || nick_name` — used as combo `displayField`
- `logintype`: 0 = admin, 1 = normal, 2 = disabled. `isAdmin($userid)` checks logintype=0

## Database: MATCH_DETAILS is bidirectional

`MATCH_DETAILS` stores **two rows per match** — one for each player from their own perspective.
`game_win`/`game_lose` are already from that `userid`'s viewpoint.
Similarly, `GAMES` stores two rows per set (one per player).

Do **not** filter by `win=1` alone when you need both players' data — query by `userid` directly to get the right perspective without flipping scores.

## ExtJS 3.4 Combo: always use `hiddenName`

A combo that submits a real value ID **must** use both:
```js
name: 'xxx_fake', hiddenName: 'xxx'
```
Using only `name` causes ExtJS 3 to submit the display text instead of the value ID.
This applies to every combo in a `FormPanel` that submits to the backend.

Working combo pattern (from `editMatch`):
```js
{ xtype: 'combo', name: 'userid_fake', hiddenName: 'userid',
  editable: true, forceSelection: true, typeAhead: true,
  triggerAction: 'all', mode: 'local',
  store: userStore, displayField: 'full_name', valueField: 'userid' }
```

## ExtJS 3.4: Panel separators

`xtype: 'tbseparator'` only works inside **Toolbars**. For spacers/dividers inside `Panel` items, use:
```js
{ xtype: 'box', autoEl: { tag: 'div', style: 'height: 20px;' } }
```

## Perl: use `%name` hash, not `full_name` splitting

In Perl backend functions that build a `%name` hash (e.g. `getSeriesMatchChallengeView`), the hash is keyed by `userid` and contains full user objects. Use fields directly:
```perl
$name{$uid}{cn_name}
$name{$uid}{point}
```
Never split the `full_name` string to extract `cn_name`.
