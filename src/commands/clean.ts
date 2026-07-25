import pc from 'picocolors';
import {
  derivedDataRoot,
  formatBytes,
  listDerivedData,
  orphans,
  removeDerivedData,
  withSizes,
} from '../derived-data.js';
import { log, pickOrphans } from '../ui.js';

export interface CleanOpts {
  yes?: boolean;
}

export async function cleanCmd(opts: CleanOpts): Promise<void> {
  const root = await derivedDataRoot();
  const entries = await listDerivedData(root);
  if (entries.length === 0) {
    log.warn(`No Xcode build data found in ${pc.dim(root)}.`);
    return;
  }

  const dead = await orphans(entries);
  if (dead.length === 0) {
    const n = entries.length;
    log.success(`Nothing to clean — no orphans among ${n} folder${n === 1 ? '' : 's'}.`);
    return;
  }

  log.step(`Measuring ${dead.length} orphaned folder${dead.length === 1 ? '' : 's'}…`);
  const sized = (await withSizes(dead)).sort((a, b) => b.size - a.size);
  const total = sized.reduce((sum, dd) => sum + dd.size, 0);
  log.info(
    `${pc.bold(formatBytes(total))} in ${sized.length} folder${sized.length === 1 ? '' : 's'} ` +
      `whose project no longer exists.`,
  );

  const picked = opts.yes ? sized : await pickOrphans(sized);
  if (picked.length === 0) {
    log.dim('Nothing selected.');
    return;
  }

  log.step(`Deleting ${picked.length} folder${picked.length === 1 ? '' : 's'}…`);
  let reclaimed = 0;
  for (const dd of picked) {
    try {
      await removeDerivedData(dd, root);
      reclaimed += dd.size;
      log.success(`${dd.name} ${pc.yellow(`(${dd.sizeLabel})`)}`);
    } catch (err) {
      log.warn(`Could not remove ${dd.name}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  log.success(`Reclaimed ${pc.bold(formatBytes(reclaimed))}.`);
}
