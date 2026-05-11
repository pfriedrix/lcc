import { spawn } from 'node:child_process';
import { execa } from 'execa';

async function resolveClaudeBin(): Promise<string> {
  try {
    const { stdout } = await execa('which', ['claude']);
    return stdout.trim();
  } catch {
    throw new Error(
      'Could not find `claude` on PATH. Install Claude Code: https://docs.claude.com/en/docs/claude-code',
    );
  }
}

export async function launchClaude(cwd: string, extraArgs: string[] = []): Promise<number> {
  const bin = await resolveClaudeBin();
  return await new Promise<number>((resolve, reject) => {
    const child = spawn(bin, extraArgs, {
      cwd,
      stdio: 'inherit',
      env: process.env,
    });
    child.on('error', reject);
    child.on('exit', (code) => resolve(code ?? 0));
  });
}
