export default {
  fetch() {
    return new Response("SubversionR PR Fast Cloudflare bridge\n", {
      headers: {
        "content-type": "text/plain; charset=utf-8",
      },
    });
  },
};
