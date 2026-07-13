export default async (request, context) => {
    const response = await context.next();
    if (request.headers.get("save-data") !== "on") return response;
    const contentType = response.headers.get("content-type") || "";
    if (!contentType.includes("text/html")) return response;
    const html = await response.text();
    const rewritten = html.replace("<html", '<html data-save-data="on"');
    return new Response(rewritten, {
        status: response.status,
        headers: response.headers,
    });
};

export const config = { path: "/*" };
