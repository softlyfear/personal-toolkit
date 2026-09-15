# claude-auto-ping

По расписанию (МСК: **07:00, 12:01, 17:02, 22:03**) отправляет в Claude Code одно короткое
сообщение — каждое открывает новое **5-часовое окно сессии** подписки. API-ключ не нужен.

Каждый вызов `claude -p` — новый сеанс, поэтому окно стартует заново. Пинг идёт с
`--no-session-persistence`: сессии не пишутся в `~/.claude` и не плодятся.

## Пререквизиты

Claude CLI установлен и выполнен вход (один раз, интерактивно):

```bash
curl -fsSL https://claude.ai/install.sh | bash   # ставит в ~/.local/bin/claude
claude                                            # вход: подписка/логин
claude -p "hi" --model haiku                      # проверка: должен ответить
```

## Настройка

```bash
cd cli/claude-auto-ping
uv sync                 # создаст .venv
uv run main.py --once   # проверка: одно сообщение сейчас и выход
```

## Автоподъём после перезагрузки (systemd user-юнит)

Юнит кладётся в `~/.config/systemd/user/` — система не трогается, root не нужен.
`@reboot` в crontab не подойдёт: `configuring_server.sh` из этого репозитория
отключает cron для всех, кроме root.

```bash
cd cli/claude-auto-ping
mkdir -p ~/.config/systemd/user
sed "s|__DIR__|$PWD|; s|__UV__|$(command -v uv)|" \
  claude-auto-ping.service.in > ~/.config/systemd/user/claude-auto-ping.service
systemctl --user daemon-reload
systemctl --user enable --now claude-auto-ping
loginctl enable-linger   # юнит стартует после ребута без ручного логина
```

Проверка и логи:

```bash
systemctl --user status claude-auto-ping
journalctl --user -u claude-auto-ping -f   # дублируется в ping.log рядом со скриптом
```

## Запуск без systemd (альтернатива)

```bash
nohup uv run main.py >/dev/null 2>&1 &   # не переживёт перезагрузку
tmux new -s ping 'uv run main.py'
```

## Конфигурация

Всё в `main.py`:

| Что                  | Где                         | По умолчанию                     |
| -------------------- | --------------------------- | -------------------------------- |
| Слоты отправки (МСК) | `SLOTS`                     | `07:00, 12:01, 17:02, 22:03`     |
| Модель               | `--model` / `DEFAULT_MODEL` | алиас `haiku` — всегда последняя |
| Текст сообщения      | `MESSAGE`                   | `hi`                             |
| Путь к claude        | `--claude`                  | `claude` из PATH                 |

При ошибке (сеть, таймаут) — до 3 попыток с интервалом 2 минуты. Часовой пояс сервера не
важен: расписание считается по `Europe/Moscow`.
