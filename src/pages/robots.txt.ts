import type { APIRoute } from "astro";

// 站点部署在仓库子路径下（base=/Server-core-manager），这两处也必须带上 base，
// 否则爬虫会去域名根目录找 _astro 与 sitemap，两边都找不到。
const base = import.meta.env.BASE_URL.replace(/\/$/, "");
const site = (import.meta.env.SITE || "").replace(/\/$/, "");

const robotsTxt = `
User-agent: *
Disallow: ${base}/_astro/

Sitemap: ${site}${base}/sitemap-index.xml
`.trim();

export const GET: APIRoute = () => {
	return new Response(robotsTxt, {
		headers: {
			"Content-Type": "text/plain; charset=utf-8",
		},
	});
};
