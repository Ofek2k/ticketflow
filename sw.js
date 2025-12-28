/* /sw.js */

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  // Expect JSON payload: { title, body, url }
  let data = { title: "TicketFlow", body: "", url: "/" };

  try {
    if (event.data) data = { ...data, ...event.data.json() };
  } catch (e) {
    // If payload isn't JSON, show a generic message
    data.body = "New notification";
  }

  event.waitUntil(
    self.registration.showNotification(data.title || "TicketFlow", {
      body: data.body || "",
      data: { url: data.url || "/" },
      // icon: "/icon-192.png",
      // badge: "/badge-72.png",
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = event.notification?.data?.url || "/";

  event.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });

      // focus any open window/tab
      for (const c of all) {
        if ("focus" in c) return c.focus();
      }

      // otherwise open
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })()
  );
});
