// Project data configuration file
// Used to manage data for the project display page

export interface Project {
	id: string;
	title: string;
	description: string;
	image: string;
	category: "scm" | "mobile" | "other";
	techStack: string[];
	status: "completed" | "in-progress" | "planned";
	liveDemo?: string;
	sourceCode?: string;
	downloadUrl?: string;
	startDate: string;
	endDate?: string;
	featured?: boolean;
	tags?: string[];
	visitUrl?: string; // 外部项目链接
	internalPage?: string; // 站内介绍页（优先于 visitUrl）
	showInCategory?: boolean; // 是否出现在页面下方的分类列表里（默认 true）
}

export const projectsData: Project[] = [
	{
		id: "server-core-manager",
		title: "Server Core Manager",
		description:
			"让带图形界面的程序在 Windows Server Core 上真正跑起来。补齐官方图形组件、添加程序、启动并排障，全部一键完成，工具自己也是图形界面。29 个功能动作，21 个系统工具入口。",
		image: "",
		category: "scm",
		techStack: [
			"PowerShell",
			"WinForms",
			"DISM",
			"WinRM",
			"Windows Admin Center",
		],
		status: "completed",
		sourceCode: "https://github.com/OrangeArtc0915/Server-core-manager",
		downloadUrl:
			"https://gitee.com/orangearc655743/server-core-manager/releases",
		startDate: "2026-09-01",
		endDate: "2026-09-19",
		featured: true,
		showInCategory: false,
		tags: ["Windows Server", "Server Core", "开源", "GPL-3.0"],
	},
	{
		id: "craftdock",
		title: "CraftDock",
		description:
			"终端里的 Minecraft 服务端管理器：实例启停、镜像下载、模组/插件一键安装、Java 运行时、备份与内网穿透，全部在 cmd / PowerShell 中完成，单文件 exe 开箱即用。",
		image: "",
		category: "scm",
		techStack: ["Node.js", "TypeScript", "blessed", "Node.js SEA"],
		status: "completed",
		sourceCode: "https://github.com/OrangeArtc0915/CraftDock",
		downloadUrl:
			"https://github.com/OrangeArtc0915/CraftDock/releases/latest",
		internalPage: "/projects/craftdock/",
		startDate: "2026-10-01",
		endDate: "2026-10-25",
		featured: false,
		tags: ["Minecraft", "TUI", "Windows Server Core", "开源"],
	},
];

// Get project statistics
export const getProjectStats = () => {
	const total = projectsData.length;
	const completed = projectsData.filter((p) => p.status === "completed").length;
	const inProgress = projectsData.filter(
		(p) => p.status === "in-progress",
	).length;
	const planned = projectsData.filter((p) => p.status === "planned").length;

	return {
		total,
		byStatus: {
			completed,
			inProgress,
			planned,
		},
	};
};

// Get projects by category
export const getProjectsByCategory = (category?: string) => {
	const list = projectsData.filter((p) => p.showInCategory !== false);
	if (!category || category === "all") {
		return list;
	}
	return list.filter((p) => p.category === category);
};

// Get featured projects
export const getFeaturedProjects = () => {
	return projectsData.filter((p) => p.featured);
};

// Get all tech stacks
export const getAllTechStack = () => {
	const techSet = new Set<string>();
	projectsData.forEach((project) => {
		project.techStack.forEach((tech) => {
			techSet.add(tech);
		});
	});
	return Array.from(techSet).sort();
};
