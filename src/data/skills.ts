// Skill data configuration file
// 本站是工具的项目主页，不是简历，所以这里的「技能」指的是**这个工具覆盖的技术面**：
// 每一块都是工具真正做过实测的功能方向。
// 注意：experience 是模板的简历语义，这里统一填本项目的存续时长，不按条目编造。

export interface Skill {
	id: string;
	name: string;
	description: string;
	icon: string; // Iconify icon name
	category: "frontend" | "backend" | "database" | "tools" | "other";
	level: "beginner" | "intermediate" | "advanced" | "expert";
	experience: {
		years: number;
		months: number;
	};
	projects?: string[]; // Related project IDs
	certifications?: string[];
	color?: string; // Skill card theme color
}

export const skillsData: Skill[] = [
	{
		id: "powershell",
		name: "PowerShell 5.1 兼容",
		description:
			"整套逻辑跑在系统自带的 Windows PowerShell 5.1 上，不依赖 PowerShell 7、不依赖外部运行时。PS 7 只在需要时可选安装。",
		icon: "mdi:powershell",
		category: "tools",
		level: "advanced",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#5391FE",
	},
	{
		id: "winrm",
		name: "WinRM 远程执行与令牌绕过",
		description:
			"识别「网络令牌下 DISM 写操作被拒绝访问」这一限制，自动改走 SYSTEM 计划任务执行；WAC 安装时 WinRM 会被重启，收尾动作全部放进任务里完成。",
		icon: "mdi:remote-desktop",
		category: "other",
		level: "advanced",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#0F6CBD",
	},
	{
		id: "fod",
		name: "按需功能（FOD）与图形组件",
		description:
			"装官方 App Compatibility FOD 并跨重启续跑；跟踪 23 个桌面体验专属组件的到位情况，明确标出补不齐的 4 个及其原因。",
		icon: "mdi:package-variant-closed",
		category: "other",
		level: "advanced",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#2563EB",
	},
	{
		id: "registry-winlogon",
		name: "注册表与登录 Shell",
		description:
			"Winlogon Shell 一键切换（explorer / 轻量启动器 / cmd / sconfig），改动前导出注册表备份；已知 Winlogon 走 CreateProcess，不能直接执行 .bat，改用批处理包装。",
		icon: "mdi:registry",
		category: "other",
		level: "intermediate",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#7C3AED",
	},
	{
		id: "lsa-secret",
		name: "LSA 机密与自动登录",
		description:
			"自动登录密码写进 LSA 机密而不是注册表明文，并用真实重启验证可用性（重启后进入 console 会话，界面自检非黑占比 98.2%）。",
		icon: "mdi:key-variant",
		category: "other",
		level: "intermediate",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#059669",
	},
	{
		id: "conhost-font",
		name: "conhost 字体与代码页",
		description:
			"摸清中文代码页 936 下 conhost 只接受自带中文字形的字体这一限制，改用「先 chcp 65001 再应用字体」的启动器方案落地 Nerd Font。",
		icon: "mdi:format-font",
		category: "other",
		level: "advanced",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#D946EF",
	},
	{
		id: "console-theme",
		name: "终端美化与可还原",
		description:
			"内置 Nerd Font + oh-my-posh（6 个主题）+ fastfetch，全程离线安装；profile、cmd AutoRun、字体、颜色可一键还原。",
		icon: "mdi:console",
		category: "tools",
		level: "intermediate",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#06B6D4",
	},
	{
		id: "dotnet-zip",
		name: ".NET 运行时就地部署",
		description:
			"以 zip 方式就地铺开 .NET 运行时：不写注册表、不进控制面板，用完删目录即可。实测补齐后 ASP.NET Core 的 Kestrel 正常启动。",
		icon: "simple-icons:dotnet",
		category: "tools",
		level: "intermediate",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#512BD4",
	},
	{
		id: "electron-tuning",
		name: "Electron / Chromium 参数调优",
		description:
			"按 PE 头判定程序类型，自动带入实测推荐参数。QQ NT 加 --disable-gpu --disable-software-rasterizer 后启动 18.2 s → 6.0 s。",
		icon: "simple-icons:electron",
		category: "tools",
		level: "intermediate",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#47848F",
	},
	{
		id: "wac",
		name: "Windows Admin Center 部署",
		description:
			"自动识别经典 MSI 与 v2 两代安装器，装完放行防火墙、设为自启、启动服务，再探测入口是否可达（实测 /shell/ HTTP 302）。",
		icon: "mdi:web",
		category: "tools",
		level: "intermediate",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#0078D4",
	},
	{
		id: "diagnose",
		name: "启动诊断",
		description:
			"程序起不来时查事件日志、WER 记录、缺失的 DLL 与运行时，给出处置建议，而不是只丢一个错误码。",
		icon: "mdi:script-text",
		category: "tools",
		level: "advanced",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#EA580C",
	},
	{
		id: "self-test",
		name: "自检与可验证",
		description:
			"界面自带 -SelfTest 与 -LayoutDump 诊断开关；每次改动都在真机上跑一遍，页面数、功能数、探测数据渲染一致性都能自动比对。",
		icon: "mdi:check-decagram",
		category: "tools",
		level: "advanced",
		experience: { years: 0, months: 1 },
		projects: ["server-core-manager"],
		color: "#16A34A",
	},
];

// Get skill statistics
export const getSkillStats = () => {
	const total = skillsData.length;
	const byLevel = {
		beginner: skillsData.filter((s) => s.level === "beginner").length,
		intermediate: skillsData.filter((s) => s.level === "intermediate").length,
		advanced: skillsData.filter((s) => s.level === "advanced").length,
		expert: skillsData.filter((s) => s.level === "expert").length,
	};
	const byCategory = {
		frontend: skillsData.filter((s) => s.category === "frontend").length,
		backend: skillsData.filter((s) => s.category === "backend").length,
		database: skillsData.filter((s) => s.category === "database").length,
		tools: skillsData.filter((s) => s.category === "tools").length,
		other: skillsData.filter((s) => s.category === "other").length,
	};

	return { total, byLevel, byCategory };
};

// Get skills by category
export const getSkillsByCategory = (category?: string) => {
	if (!category || category === "all") {
		return skillsData;
	}
	return skillsData.filter((s) => s.category === category);
};

// Get advanced skills
export const getAdvancedSkills = () => {
	return skillsData.filter(
		(s) => s.level === "advanced" || s.level === "expert",
	);
};

// Calculate total years of experience
export const getTotalExperience = () => {
	const totalMonths = skillsData.reduce((total, skill) => {
		return total + skill.experience.years * 12 + skill.experience.months;
	}, 0);
	return {
		years: Math.floor(totalMonths / 12),
		months: totalMonths % 12,
	};
};
