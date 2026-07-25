import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import Icons from 'unplugin-icons/vite'

export default defineConfig({
	integrations: [sitemap()],
	vite: {
		plugins: [tailwindcss(), Icons({
			compiler: "astro"
		})],
	}
});
