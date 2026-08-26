import { createServer } from "node:http";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { storeFor } from "./secrets.js";

const config = loadConfig();
createServer(createApp(config, storeFor(config))).listen(config.port, () => {
  console.log(`token broker listening on :${config.port} as ${config.brokerUrl}`);
});
