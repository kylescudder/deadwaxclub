import {
  mkdir,
  open,
  rename,
  readdir,
  readFile,
  unlink
} from 'node:fs/promises'
import { join } from 'node:path'
import { hash } from './native-oauth'

// Keep original signed bytes. File and directory fsync precede acknowledging
// storage. A 503 while fenced also keeps Apple's source-side retry active.
export class NotificationSpool {
  constructor(private readonly directory: string) {}
  async retain(payload: string) {
    await mkdir(this.directory, { recursive: true, mode: 0o700 })
    const name = hash(payload) + '.json',
      temporary = join(
        this.directory,
        name + '.' + crypto.randomUUID() + '.tmp'
      )
    const file = await open(temporary, 'wx', 0o600)
    try {
      await file.writeFile(JSON.stringify({ signedPayload: payload }))
      await file.sync()
    } finally {
      await file.close()
    }
    await rename(temporary, join(this.directory, name))
    const dir = await open(this.directory, 'r')
    try {
      await dir.sync()
    } finally {
      await dir.close()
    }
    return name
  }
  async replay(process: (payload: string) => Promise<void>) {
    await mkdir(this.directory, { recursive: true, mode: 0o700 })
    for (const name of await readdir(this.directory)) {
      if (!name.endsWith('.json')) continue
      const body = JSON.parse(
        await readFile(join(this.directory, name), 'utf8')
      ) as { signedPayload: string }
      await process(body.signedPayload)
      await unlink(join(this.directory, name))
    }
  }
}
