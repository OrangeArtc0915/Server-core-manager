/**
 * Marks this process as the TUI. The daemon logger reads this flag while it is
 * being loaded and keeps the console appender disabled: raw log lines written
 * to stdout corrupt the blessed alternate screen.
 *
 * Must be imported before any daemon service (see main.ts).
 */
process.env.MCSM_TUI = "1";
