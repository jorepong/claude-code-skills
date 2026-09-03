import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const runtimeDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const slug = process.argv[2] ?? '';

if (!/^[a-z0-9][a-z0-9-]*$/.test(slug)) {
  throw new Error(`잘못된 주제 슬러그: ${slug}`);
}

const topicEntry = path.join(runtimeDir, 'src', slug, 'index.jsx');
if (!fs.existsSync(topicEntry)) {
  throw new Error(`진입점 없음: ${topicEntry}`);
}

const generatedDir = path.join(runtimeDir, 'src', '.generated');
fs.mkdirSync(generatedDir, {recursive: true});
const generatedEntry = path.join(generatedDir, `${slug}.jsx`);
const source = `import '../${slug}/index.jsx';\nimport {registerRoot} from 'remotion';\nimport {LearnRoot} from '../lib/root.jsx';\nregisterRoot(LearnRoot);\n`;
fs.writeFileSync(generatedEntry, source);
process.stdout.write(generatedEntry);
