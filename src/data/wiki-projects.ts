// 文档（wiki）按项目拆分，这里放每个项目的展示信息
export type WikiProjectKey = "scm" | "craftdock" | "scterm";

export interface WikiProject {
	key: WikiProjectKey;
	name: string;
	subtitle: string;
	icon: string;
	tags: string[];
	repo: string;
}

export const wikiProjects: WikiProject[] = [
	{
		key: "scm",
		name: "Server Core Manager",
		subtitle:
			"让图形程序在 Windows Server Core 上真正跑起来：补组件、加程序、排障，全部一键完成。",
		icon: "material-symbols:desktop-windows",
		tags: ["Windows Server", "Server Core", "PowerShell"],
		repo: "https://github.com/OrangeArtc0915/Server-core-manager",
	},
	{
		key: "craftdock",
		name: "CraftDock",
		subtitle:
			"终端里的 Minecraft 服务端管理器：实例启停、镜像下载、模组插件安装、备份与内网穿透。",
		icon: "material-symbols:terminal",
		tags: ["Minecraft", "TUI", "Node.js SEA"],
		repo: "https://github.com/OrangeArtc0915/CraftDock",
	},
	{
		key: "scterm",
		name: "scterm",
		subtitle:
			"Windows Server Core 上的终端多路复用工具：标签页、窗格分屏、布局模板、会话恢复、回看搜索与 PowerShell 托管。",
		icon: "material-symbols:keyboard-command-key",
		tags: ["Windows Server Core", "Rust", "TUI", "PowerShell"],
		repo: "https://github.com/OrangeArtc0915/Server-core-manager",
	},
];

export const getWikiProject = (key: string) =>
	wikiProjects.find((project) => project.key === key);

/**
 * 文档条目在 URL 里的 slug。
 * 某个项目的文档放在同名子目录（如 wiki/craftdock/install.md）时，去掉目录前缀。
 */
export const wikiSlug = (slug: string, project: string) =>
	slug.startsWith(`${project}/`) ? slug.slice(project.length + 1) : slug;
