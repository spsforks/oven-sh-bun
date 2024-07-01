const dgram = require("internal/dgram");
const net = require("node:net");

export default class SharedHandle {
  key;
  workers;
  handle;
  errno;

  constructor(key, address, { port, addressType, fd, flags }) {
    this.key = key;
    this.workers = new Map();
    this.handle = null;
    this.errno = 0;

    let rval;
    if (addressType === "udp4" || addressType === "udp6")
      rval = dgram._createSocketHandle(address, port, addressType, fd, flags);
    else rval = net._createServerHandle(address, port, addressType, fd, flags);

    if (typeof rval === "number") this.errno = rval;
    else this.handle = rval;
  }

  add(worker, send) {
    // $assert(!this.workers.has(worker.id));
    this.workers.set(worker.id, worker);
    send(this.errno, null, this.handle);
  }

  remove(worker) {
    if (!this.workers.has(worker.id)) return false;

    this.workers.delete(worker.id);

    if (this.workers.size !== 0) return false;

    this.handle.close();
    this.handle = null;
    return true;
  }
}
