// Textm 自有插件 API（Boa）：命令、编辑、工作区、窗口、事件。
// 与 Rust 的交互统一走 globalThis.__textm（字符串/JSON），避免复杂对象桥接。
(function () {
  'use strict';
  var native = globalThis.__textm;
  var VERSION = '2.0.0';

  function parse(text) {
    try {
      return JSON.parse(text);
    } catch (e) {
      return null;
    }
  }
  function dump(value) {
    try {
      return JSON.stringify(value === undefined ? null : value);
    } catch (e) {
      return 'null';
    }
  }
  function log(text) {
    native.log(String(text));
  }
  function guard(fn, fallback) {
    try {
      return fn();
    } catch (e) {
      log('插件异常：' + (e && e.stack ? e.stack : e));
      return fallback;
    }
  }

  function Disposable(fn) {
    this._fn = fn;
  }
  Disposable.prototype.dispose = function () {
    if (this._fn) {
      try {
        this._fn();
      } catch (e) {}
      this._fn = null;
    }
  };

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function utf8Encode(text) {
    var out = [];
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i);
      if (code < 0x80) out.push(code);
      else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      else if (code < 0xd800 || code >= 0xe000) {
        out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      } else {
        i++;
        var next = text.charCodeAt(i) || 0;
        var cp = 0x10000 + (((code & 0x3ff) << 10) | (next & 0x3ff));
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      }
    }
    return out;
  }
  function utf8Decode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; ) {
      var b = bytes[i++];
      if (b < 0x80) out += String.fromCharCode(b);
      else if (b < 0xe0) out += String.fromCharCode(((b & 31) << 6) | (bytes[i++] & 63));
      else if (b < 0xf0) {
        out += String.fromCharCode(((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63));
      } else {
        var cp = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
      }
    }
    return out;
  }
  function bytesToBase64(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var a = bytes[i];
      var b = i + 1 < bytes.length ? bytes[i + 1] : 0;
      var c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += B64[a >> 2];
      out += B64[((a & 3) << 4) | (b >> 4)];
      out += i + 1 < bytes.length ? B64[((b & 15) << 2) | (c >> 6)] : '=';
      out += i + 2 < bytes.length ? B64[c & 63] : '=';
    }
    return out;
  }
  function base64ToBytes(text) {
    var clean = String(text).replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [];
    for (var i = 0; i < clean.length; i += 4) {
      var a = B64.indexOf(clean[i]);
      var b = B64.indexOf(clean[i + 1]);
      var c = B64.indexOf(clean[i + 2]);
      var d = B64.indexOf(clean[i + 3]);
      out.push((a << 2) | (b >> 4));
      if (c >= 0) out.push(((b & 15) << 4) | (c >> 2));
      if (d >= 0) out.push(((c & 3) << 6) | d);
    }
    return out;
  }

  function fsCall(op, path, data) {
    return parse(native.fs(String(op), String(path || ''), data === undefined ? '' : String(data))) || {};
  }
  function activeInfo() {
    return parse(native.activeDoc()) || {};
  }
  function activePath() {
    return activeInfo().path || '';
  }
  function applyEdits(edits) {
    var path = activePath();
    if (path) native.applyEdits(path, dump(edits));
  }
  function point(line, column) {
    if (Array.isArray(line)) return { line: line[0] | 0, character: (line[1] | 0) || 0 };
    if (line && line.line !== undefined) return { line: line.line | 0, character: (line.column !== undefined ? line.column : line.character) | 0 };
    return { line: line | 0, character: column | 0 };
  }

  var handlers = {};
  var events = { save: [], open: [], change: [] };

  var pathModule = {
    sep: '\\',
    join: function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) {
        if (arguments[i] !== undefined && arguments[i] !== null && arguments[i] !== '') parts.push(String(arguments[i]));
      }
      return parts.join('\\').replace(/\//g, '\\').replace(/\\\\+/g, '\\');
    },
    dirname: function (p) {
      var text = String(p).replace(/\//g, '\\');
      var index = text.lastIndexOf('\\');
      return index <= 0 ? '.' : text.slice(0, index);
    },
    basename: function (p) {
      var text = String(p).replace(/\//g, '\\');
      var index = text.lastIndexOf('\\');
      return index < 0 ? text : text.slice(index + 1);
    },
    extname: function (p) {
      var name = pathModule.basename(p);
      var index = name.lastIndexOf('.');
      return index <= 0 ? '' : name.slice(index);
    }
  };

  var api = {
    version: VERSION,
    path: pathModule,
    commands: {
      register: function (id, handler) {
        var key = String(id);
        handlers[key] = handler;
        native.commandRegistered(key, '');
        return new Disposable(function () {
          delete handlers[key];
        });
      },
      execute: function (id) {
        var handler = handlers[String(id)];
        if (!handler) return Promise.reject(new Error('未注册命令 ' + id));
        var args = Array.prototype.slice.call(arguments, 1);
        try {
          return Promise.resolve(handler.apply(null, args));
        } catch (e) {
          log('命令 ' + id + ' 失败：' + (e && e.stack ? e.stack : e));
          return Promise.reject(e);
        }
      },
      getAll: function () {
        return Object.keys(handlers);
      }
    },
    editor: {
      active: activeInfo,
      getText: function () {
        return activeInfo().text || '';
      },
      lineCount: function () {
        return String(activeInfo().text || '').split(/\r\n|\r|\n/).length;
      },
      getLine: function (index) {
        var lines = String(activeInfo().text || '').split(/\r\n|\r|\n/);
        return lines[index | 0] || '';
      },
      cursor: function () {
        var info = activeInfo();
        return { line: info.line || 0, column: info.character || 0 };
      },
      selection: function () {
        var info = activeInfo();
        if (info.selStartLine === undefined) return null;
        return {
          start: { line: info.selStartLine, column: info.selStartCharacter },
          end: { line: info.selEndLine, column: info.selEndCharacter }
        };
      },
      insert: function (text) {
        var info = activeInfo();
        var at = { line: info.line || 0, character: info.character || 0 };
        applyEdits([{ start: at, end: at, newText: String(text) }]);
      },
      replace: function (start, end, text) {
        applyEdits([{ start: point(start), end: point(end), newText: String(text) }]);
      },
      setText: function (text) {
        var info = activeInfo();
        var lines = String(info.text || '').split(/\r\n|\r|\n/).length;
        applyEdits([
          {
            start: { line: 0, character: 0 },
            end: { line: lines + 1, character: 0 },
            newText: String(text)
          }
        ]);
      },
      open: function (path) {
        var info = parse(native.openDocument(String(path))) || {};
        native.showDocument(String(path), 0, 0);
        return info;
      },
      save: function () {
        var path = activePath();
        if (path) native.saveDocument(path);
      },
      goto: function (line, column) {
        native.showDocument(activePath(), line | 0, column | 0);
      }
    },
    workspace: {
      root: function () {
        var info = parse(native.workspace()) || {};
        return info.folders && info.folders[0] ? info.folders[0].path : '';
      },
      folders: function () {
        var info = parse(native.workspace()) || {};
        return (info.folders || []).map(function (folder) {
          return folder.path;
        });
      },
      readText: function (path) {
        var text = native.readTextFile(String(path));
        return text === null ? null : text;
      },
      writeText: function (path, text) {
        return fsCall('write', path, bytesToBase64(utf8Encode(String(text)))).error || null;
      },
      readBytes: function (path) {
        var result = fsCall('read', path);
        return result.error ? null : base64ToBytes(result.data || '');
      },
      writeBytes: function (path, bytes) {
        var data = Array.isArray(bytes) ? bytes : [];
        return fsCall('write', path, bytesToBase64(data)).error || null;
      },
      readDir: function (path) {
        var result = fsCall('readdir', path);
        return (result.items || []).map(function (item) {
          return { name: item.name, path: pathModule.join(String(path), item.name), dir: !!item.dir };
        });
      },
      exists: function (path) {
        return !!fsCall('exists', path).exists;
      },
      stat: function (path) {
        var result = fsCall('stat', path);
        return result.error ? null : { dir: !!result.dir, size: result.size || 0 };
      },
      mkdir: function (path) {
        fsCall('mkdir', path);
      },
      remove: function (path) {
        fsCall('remove', path);
      },
      rename: function (from, to) {
        fsCall('rename', from, to);
      },
      copy: function (from, to) {
        fsCall('copy', from, to);
      },
      findFiles: function (limit) {
        return parse(native.findFiles(limit || 400)) || [];
      },
      config: function () {
        return parse(native.config()) || {};
      }
    },
    window: {
      info: function (text) {
        native.message(1, String(text));
      },
      warn: function (text) {
        native.message(2, String(text));
      },
      error: function (text) {
        native.message(3, String(text));
      },
      status: function (text) {
        native.status(String(text));
      },
      output: function (text) {
        native.output(String(text));
      },
      log: log,
      terminal: function (command) {
        native.terminal(String(command));
      },
      panel: function (title, text) {
        native.panel(String(title), String(text));
      },
      input: function (prompt, value) {
        return new Promise(function (resolve) {
          var id = native.nextId();
          resolvers[String(id)] = function (text) {
            resolve(text === null ? undefined : parse(text));
          };
          native.inputBox(id, String(prompt || '插件输入'), String(value || ''));
        });
      },
      pick: function (items, placeholder) {
        return new Promise(function (resolve) {
          var id = native.nextId();
          resolvers[String(id)] = function (text) {
            resolve(text === null ? undefined : parse(text));
          };
          native.quickPick(id, dump(items || []), String(placeholder || '插件选择'));
        });
      },
      problems: function (path, items) {
        var list = (items || []).map(function (item) {
          return {
            message: String(item.message || ''),
            severity: item.severity === undefined ? 0 : item.severity,
            source: String(item.source || ''),
            line: item.line || 0,
            character: item.character || 0
          };
        });
        native.problems(String(path || ''), dump(list));
      }
    },
    events: {
      on: function (name, handler) {
        var key = String(name);
        if (!events[key]) events[key] = [];
        events[key].push(handler);
        return new Disposable(function () {
          var index = events[key].indexOf(handler);
          if (index >= 0) events[key].splice(index, 1);
        });
      }
    },
    clipboard: {
      read: function () {
        return native.clipboardRead() || '';
      },
      write: function (text) {
        native.clipboardWrite(String(text));
      }
    },
    log: log,
    env: {
      appName: 'Textm',
      version: VERSION,
      platform: 'win32',
      get workspace() {
        return api.workspace.root();
      }
    }
  };

  var resolvers = {};
  globalThis.__textmResolve = function (id, json) {
    var fn = resolvers[String(id)];
    if (fn) {
      delete resolvers[String(id)];
      try {
        fn(json);
      } catch (e) {
        log('解析回调失败：' + e);
      }
    }
  };

  globalThis.__textmInvokeCommand = function (id, argsJson) {
    var handler = handlers[String(id)];
    if (!handler) return 'missing';
    try {
      handler.apply(null, parse(argsJson) || []);
      return 'ok';
    } catch (e) {
      log('命令 ' + id + ' 失败：' + (e && e.stack ? e.stack : e));
      return 'error';
    }
  };

  // 定时器（Boa 无内置，Rust 在 tick 中推进）
  var timers = [];
  globalThis.setTimeout = function (fn) {
    timers.push({ fn: fn });
    return timers.length;
  };
  globalThis.setInterval = globalThis.setTimeout;
  globalThis.clearTimeout = function () {};
  globalThis.clearInterval = function () {};
  globalThis.__textmRunTimers = function () {
    if (!timers.length) return;
    var pending = timers;
    timers = [];
    for (var i = 0; i < pending.length; i++) {
      guard(pending[i].fn);
    }
  };
  globalThis.setImmediate = globalThis.setTimeout;

  // 模块加载（只支持相对路径与 textm 内置）
  var moduleCache = {};
  function loadModule(file) {
    var key = pathModule.join(String(file));
    if (moduleCache[key]) return moduleCache[key].exports;
    var module = { exports: {} };
    moduleCache[key] = module;
    if (/\.json$/i.test(key)) {
      module.exports = parse(native.readTextFile(key) || 'null');
      return module.exports;
    }
    var code = native.readTextFile(key);
    if (code === null) throw new Error('无法读取模块：' + key);
    var factory = eval(
      "(function(module, exports, require){\n" + code + "\n})"
    );
    var localRequire = function (spec) {
      if (spec === 'textm') return api;
      if (spec === 'vscode') {
        throw new Error("Textm 插件请使用 textm API（globalThis.textm），不支持 vscode 模块");
      }
      if (String(spec).charAt(0) !== '.') {
        throw new Error('不支持的内置模块 ' + spec + '，请使用 textm.workspace / textm.editor');
      }
      var target = pathModule.join(pathModule.dirname(key), String(spec));
      if (!/\.(js|json)$/i.test(target)) target += '.js';
      return loadModule(target);
    };
    factory(module, module.exports, localRequire);
    return module.exports;
  }
  globalThis.__textmLoadFile = loadModule;
  globalThis.__textmLoadPlugin = function (mainPath, pluginDir, manifestJson, storagePath) {
    try {
      var exportsObject = loadModule(mainPath);
      var context = {
        textm: api,
        pluginPath: pluginDir,
        storagePath: storagePath,
        manifest: parse(manifestJson) || {},
        appVersion: VERSION,
        subscriptions: []
      };
      if (exportsObject && typeof exportsObject.activate === 'function') {
        exportsObject.activate(context);
      }
      globalThis.__textmDeactivate = function () {
        if (exportsObject && typeof exportsObject.deactivate === 'function') {
          exportsObject.deactivate();
        }
      };
      return 'ok';
    } catch (e) {
      log('激活插件失败 ' + mainPath + '：' + (e && e.stack ? e.stack : e));
      return 'error';
    }
  };

  globalThis.__textmFire = function (name, json) {
    var list = events[String(name)] || [];
    var payload = parse(json);
    list.slice().forEach(function (handler) {
      guard(function () {
        handler(payload);
      });
    });
  };

  globalThis.textm = api;
  globalThis.Disposable = Disposable;
})();
