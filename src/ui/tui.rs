//! TUI 事件循环：渲染 → 读取事件 → 更新状态。

use std::path::PathBuf;

use crate::config::Config;
use crate::platform::console::{Console, Event as ConsoleEvent};
use crate::platform::log;
use crate::ui::app::{App, Event};

pub fn run(config: Config, files: Vec<PathBuf>) -> Result<i32, String> {
    let mut console = Console::new()?;
    let restore = files.is_empty();
    let mut app = App::new(config, files, false);
    let (cols, rows) = console.size();
    app.resize(cols as usize, rows as usize);
    if restore {
        app.restore_session();
    }
    console.set_title("Textm 2.0");
    log::info(&format!("TUI 启动：{}x{}", cols, rows));

    loop {
        let canvas = app.render();
        console.present(&canvas.grid);
        console.set_cursor(app.cursor_screen());

        match console.read_event(60) {
            Some(ConsoleEvent::Key(key)) => app.handle(Event::Key(key)),
            Some(ConsoleEvent::Mouse(mouse)) => app.handle(Event::Mouse(mouse)),
            Some(ConsoleEvent::Resize(cols, rows)) => {
                app.handle(Event::Resize(cols as usize, rows as usize))
            }
            Some(ConsoleEvent::Focus(_)) => {}
            None => app.handle(Event::Tick),
        }
        if !app.running {
            break;
        }
    }
    console.restore();
    log::info("TUI 退出");
    Ok(0)
}
