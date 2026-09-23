// Project data configuration file
// Used to manage data for the project display page

export interface Project {
	id: string;
	title: string;
	description: string;
	image: string;
	category: "web" | "mobile" | "desktop" | "other";
	techStack: string[];
	status: "completed" | "in-progress" | "planned";
	liveDemo?: string;
	sourceCode?: string;
	startDate: string;
	endDate?: string;
	featured?: boolean;
	tags?: string[];
	visitUrl?: string; // 添加前往项目链接字段
}

export const projectsData: Project[] = [
	{
		id: "server-core-manager",
		title: "Server Core Manager",
		description:
			"让带图形界面的程序在 Windows Server Core 上真正跑起来。补齐官方图形组件、添加程序、启动并排障，全部一键完成，工具自己也是图形界面。29 个功能动作，21 个系统工具入口。",
		image: "",
		category: "desktop",
		techStack: ["PowerShell", "WinForms", "DISM", "WinRM", "Windows Admin Center"],
		status: "completed",
		sourceCode: "https://github.com/OrangeArtc0915/Server-core-manager",
		visitUrl: "https://gitee.com/orangearc655743/server-core-manager/releases",
		startDate: "2026-09-01",
		endDate: "2026-09-19",
		featured: true,
		tags: ["Windows Server", "Server Core", "开源", "GPL-3.0"],
	},
	{
		id: "server-core-manager-site",
		title: "项目主页（本站）",
		description:
			"用 Astro 构建的项目主页，把工具的设计取舍与实测记录整理成文章。所有数字与结论都来自真机测试，并附上复现方式。",
		image: "",
		category: "web",
		techStack: ["Astro", "TypeScript", "Tailwind CSS", "Svelte"],
		status: "completed",
		sourceCode: "https://github.com/OrangeArtc0915/Server-core-manager/tree/WEB",
		startDate: "2026-09-19",
		endDate: "2026-09-19",
		tags: ["Astro", "静态站点", "文档"],
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
	if (!category || category === "all") {
		return projectsData;
	}
	return projectsData.filter((p) => p.category === category);
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
