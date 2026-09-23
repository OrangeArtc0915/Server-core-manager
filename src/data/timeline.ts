// Timeline data configuration file
// 这里是**版本演进**：本站是工具的项目主页，时间线记的是每个版本做了什么。

export interface TimelineItem {
	id: string;
	title: string;
	description: string;
	type: "education" | "work" | "project" | "achievement";
	startDate: string;
	endDate?: string; // If empty, it means current
	location?: string;
	organization?: string;
	position?: string;
	skills?: string[];
	achievements?: string[];
	links?: {
		name: string;
		url: string;
		type: "website" | "certificate" | "project" | "other";
	}[];
	icon?: string; // Iconify icon name
	color?: string;
	featured?: boolean;
}

export const timelineData: TimelineItem[] = [
	{
		id: "v1-1-0",
		title: "v1.1.0 · 启动提速与终端美化",
		description:
			"环境探测挪到后台子进程，界面累计冻结从 2613 ms 降到 447 ms；功能精简到 29 个；新增终端美化（Nerd Font + oh-my-posh + fastfetch，6 个内置主题）与终端入口提示；Windows 终端相关功能因实测不可用全部移除。",
		type: "achievement",
		startDate: "2026-09-19",
		skills: ["PowerShell", "WinForms", "conhost", "oh-my-posh"],
		achievements: [
			"界面累计冻结 2613 ms → 447 ms，单次最长 1086 ms → 228 ms",
			"功能动作 37 → 29 个，去掉在真 Server Core 上不可行的路线",
			"终端美化全程离线，可一键还原",
			"Gitee 一行安装线路，下载按 zip 魔数校验内容",
		],
		links: [
			{
				name: "发布包（Gitee）",
				url: "https://gitee.com/orangearc655743/server-core-manager/releases",
				type: "website",
			},
			{
				name: "发布说明",
				url: "https://github.com/OrangeArtc0915/Server-core-manager/blob/main/RELEASE_NOTES.md",
				type: "project",
			},
		],
		icon: "material-symbols:rocket-launch",
		color: "#2563EB",
		featured: true,
	},
	{
		id: "v1-0-0",
		title: "v1.0.0 · 首个公开版本",
		description:
			"把「补全图形环境 → 添加程序 → 启动并排障」做成一键操作，并自带图形界面。含 4 个界面页面、32 个功能动作、20 个系统工具入口。",
		type: "achievement",
		startDate: "2026-09-19",
		skills: ["PowerShell", "DISM", "WinRM"],
		achievements: [
			"官方 App Compatibility FOD 一键安装，支持跨重启续跑",
			"Windows Admin Center 一键部署（自动识别 MSI 与 v2 安装器）",
			"程序档案按 PE 头判定类型，自动带入实测推荐参数",
			"自动登录用 LSA 机密，密码不进注册表明文",
		],
		links: [
			{
				name: "源码仓库",
				url: "https://github.com/OrangeArtc0915/Server-core-manager",
				type: "project",
			},
		],
		icon: "material-symbols:star",
		color: "#059669",
		featured: true,
	},
	{
		id: "v0-0-0",
		title: "v0.0.0 · 第一条可用链路",
		description:
			"打通最小可用路径：远程探明环境、装 FOD、重启后拉起图形程序。同时确认了一批「流传的说法」是错的，写进代码当判据。",
		type: "project",
		startDate: "2026-09-19",
		skills: ["PowerShell", "WinRM", "DISM"],
		achievements: [
			"实测确认 Server-Gui-Shell 在 Server Core 上不存在",
			"实测确认 WinRM 网络令牌下 DISM 写操作被拒绝访问",
			"Electron 程序加禁用 GPU 参数后启动 18.2 s → 6.0 s",
		],
		icon: "material-symbols:build",
		color: "#7C3AED",
	},
	{
		id: "project-start",
		title: "项目启动 · 确定路线",
		description:
			"目标是让带图形界面的程序在 Windows Server Core 上真正跑起来，且不给运维增加手工步骤：一条命令装好、双击即可运行、能看日志。",
		type: "project",
		startDate: "2026-09-01",
		skills: ["PowerShell", "Windows Server"],
		icon: "material-symbols:lightbulb",
		color: "#EA580C",
	},
];

// Get timeline statistics
export const getTimelineStats = () => {
	const total = timelineData.length;
	const byType = {
		education: timelineData.filter((item) => item.type === "education").length,
		work: timelineData.filter((item) => item.type === "work").length,
		project: timelineData.filter((item) => item.type === "project").length,
		achievement: timelineData.filter((item) => item.type === "achievement")
			.length,
	};

	return { total, byType };
};

// Get timeline items by type
export const getTimelineByType = (type?: string) => {
	if (!type || type === "all") {
		return timelineData.sort(
			(a, b) =>
				new Date(b.startDate).getTime() - new Date(a.startDate).getTime(),
		);
	}
	return timelineData
		.filter((item) => item.type === type)
		.sort(
			(a, b) =>
				new Date(b.startDate).getTime() - new Date(a.startDate).getTime(),
		);
};

// Get featured timeline items
export const getFeaturedTimeline = () => {
	return timelineData
		.filter((item) => item.featured)
		.sort(
			(a, b) =>
				new Date(b.startDate).getTime() - new Date(a.startDate).getTime(),
		);
};

// Get current ongoing items
export const getCurrentItems = () => {
	return timelineData.filter((item) => !item.endDate);
};

// Calculate total work experience
export const getTotalWorkExperience = () => {
	const workItems = timelineData.filter((item) => item.type === "work");
	let totalMonths = 0;

	workItems.forEach((item) => {
		const startDate = new Date(item.startDate);
		const endDate = item.endDate ? new Date(item.endDate) : new Date();
		const diffTime = Math.abs(endDate.getTime() - startDate.getTime());
		const diffMonths = Math.ceil(diffTime / (1000 * 60 * 60 * 24 * 30));
		totalMonths += diffMonths;
	});

	return {
		years: Math.floor(totalMonths / 12),
		months: totalMonths % 12,
	};
};
