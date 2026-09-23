// 从已安装的 @iconify-json/* 里抽出「Svelte 组件实际用到的图标」，生成本地集合，
// 让运行时不再去 api.iconify.design 取图标数据。
//
//   pnpm run icons
//
// 什么时候要重跑：在 .svelte 里新加了 <Icon icon="prefix:name" /> 之后。
// 不重跑的后果：新图标不在本地集合里，那个图标会去 api.iconify.design 取 —— 国内
// 可能取不到，表现就是那一个图标不显示。
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const srcDir = path.join(root, "src");
const outFile = path.join(srcDir, "data", "iconify-local.json");

// 1) 收集所有 Svelte 里 <Icon icon="prefix:name" ...> 用到的图标名
const used = new Map();
function walk(dir) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			walk(p);
			continue;
		}
		if (!/\.svelte$/.test(e.name)) continue;
		const text = fs.readFileSync(p, "utf8");
		// 只认 @iconify/svelte 的 Icon（astro-icon 的 <Icon name=...> 是构建期内联的，不用管）
		for (const m of text.matchAll(/\bicon="([a-z0-9-]+):([a-z0-9-]+)"/g)) {
			if (!used.has(m[1])) used.set(m[1], new Set());
			used.get(m[1]).add(m[2]);
		}
	}
}
walk(srcDir);

// 2) 从 node_modules 的图标包里抽出用到的图标
const collections = [];
for (const [prefix, names] of used) {
	const pkg = path.join(root, "node_modules", "@iconify-json", prefix, "icons.json");
	if (!fs.existsSync(pkg)) {
		console.log(`跳过 ${prefix}：未安装 @iconify-json/${prefix}（用到 ${[...names].join(", ")}）`);
		continue;
	}
	const data = JSON.parse(fs.readFileSync(pkg, "utf8"));
	const icons = {};
	const missing = [];
	for (const name of names) {
		const hit = (data.icons && data.icons[name]) || (data.aliases && data.aliases[name]);
		if (hit) icons[name] = hit;
		else missing.push(name);
	}
	collections.push({ prefix: data.prefix, icons, width: data.width, height: data.height });
	console.log(
		`${prefix}: ${Object.keys(icons).length} 个${missing.length ? `（包里没有：${missing.join(", ")}）` : ""}`,
	);
}

fs.writeFileSync(outFile, JSON.stringify(collections), "utf8");
console.log(
	`已写出 ${path.relative(root, outFile)}（${collections.length} 个集合，${(fs.statSync(outFile).size / 1024).toFixed(1)} KB）`,
);
