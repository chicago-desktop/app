# Widget-owned settings

The host owns Add Widget, Widget Properties and the instance YAML. The widget
owns its configurable fields and validates its own `config` when it starts.
There are no Weather/Task Manager branches in the host editor.

A definition may declare `meta.settings.fields`, an ordered list:

```yaml
settings:
  fields:
    - key: show_history
      type: boolean
      label: Show history graph
      default: true
```

Supported types are `boolean`, `text`, `select` (an `options` list of
`{value, label}`), and `lookup` (one lookup field per form). `required: true`
rejects an empty value. Existing unknown configuration keys are preserved.
Values are stored under the field's `key` in instance `data.config`; defaults
are copied only into the editor draft. Cancel does not write them.

A lookup declares `label_fields` and a service protocol. Weather owns this
example, including the service that performs geocoding:

```yaml
- key: place
  type: lookup
  label: City
  label_fields: [name, admin1, country]
  provider:
    service: chicago.weather
    topic: weather.ask
    reply: weather.reply
    operation: search
```

The editor subscribes before sending `{op, query}`. The provider replies to
its sender with `{ok, query, results}` or `{ok: false, query, error}`. Results
are plain data; selecting a result copies it into `config[key]`. Replies for
an older query are ignored. The window releases subscriptions on close.
Widget-specific validation remains the widget's responsibility, including
configuration supplied directly through YAML.

The General tab uses a host grid: `1 x 1` through `3 x 3` (nine choices). One
grid unit maps to 10 terminal columns by 4 rows including the panel frame.
The SDK still applies its desktop-width cap. Existing cell sizes stay Custom
until a preset is explicitly selected. This is a size picker, not desktop
placement or mouse resizing. Saved dimensions still pass SDK/definition bounds.

Saving uses the file version loaded by that dialog. Concurrent changes from
another dialog, manager or external editor cause a conflict instead of
silently overwriting them. Close the conflicting dialog and reopen it to load
the new version. The manager rereads saved composition changes every two seconds.
Changing config restarts only that widget instance through the SDK reconciler.
