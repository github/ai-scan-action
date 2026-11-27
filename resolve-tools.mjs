import { execFileSync } from 'node:child_process'
import { appendFileSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const ASSET_NAME = 'ai-scan.tar.xz'
const NODE_ENTRY_POINT = 'argus.mjs'
const BUN_ENTRY_POINT = 'argus.js'
const BUN_VERSION_STAMP = 'ai-scan-bun-version'
const PUBLIC_DISTRIBUTION_REPOSITORY = 'github/ai-scan-action'

function emitErrorAnnotation(message) {
  console.log(`::error::${message.replace(/[\r\n]+/g, ' ')}`)
}

function emitWarningAnnotation(message, log = console.log) {
  log(`::warning::${message.replace(/[\r\n]+/g, ' ')}`)
}

function commandOutput(command, args, env = process.env) {
  return execFileSync(command, args, {
    encoding: 'utf8',
    env,
    stdio: ['ignore', 'pipe', 'inherit'],
  })
}

function gh(args, host = 'github.com') {
  return commandOutput('gh', args, { ...process.env, GH_HOST: host }).trim()
}

function curl(args) {
  return commandOutput('curl', [
    '--fail',
    '--silent',
    '--show-error',
    '--retry',
    '3',
    ...args,
  ]).trim()
}

function tar(args) {
  return commandOutput('tar', args)
}

export function parseLatestReleaseTag(latestUrl, releaseRepository) {
  const url = new URL(latestUrl)
  const tagPrefix = `/${releaseRepository}/releases/tag/`
  if (
    url.origin !== 'https://github.com' ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !url.pathname.startsWith(tagPrefix) ||
    url.pathname.length === tagPrefix.length
  ) {
    throw new Error(`Unexpected latest release redirect for ${releaseRepository}: ${latestUrl}`)
  }
  return url.pathname.slice(tagPrefix.length)
}

function featureApiHost(apiUrl) {
  const url = new URL(apiUrl)
  if (url.protocol !== 'https:' || url.username || url.password) {
    throw new Error('Invalid GitHub API URL')
  }
  const hostname = url.hostname.replace(/^api\./, '')
  return `${hostname}${url.port ? `:${url.port}` : ''}`
}

function readUseNextRelease(repository, apiUrl, { gh, log }) {
  try {
    const value = gh(
      [
        'api',
        '--method',
        'GET',
        `repos/${repository}/code-scanning/ai-scan-action/features`,
        '-f',
        'features=use_next_release',
        '--jq',
        '.use_next_release // false',
      ],
      featureApiHost(apiUrl),
    )
    if (value !== 'true' && value !== 'false') {
      throw new Error('Feature API returned an invalid use_next_release value')
    }
    return value === 'true'
  } catch (error) {
    emitWarningAnnotation(
      `Could not read the pending AI Scan release feature flag; using latest (${error.message})`,
      log,
    )
    return false
  }
}

function resolvePendingTag(releaseRepository, gh) {
  return gh([
    'release',
    'list',
    '--repo',
    releaseRepository,
    '--order',
    'desc',
    '--limit',
    '1',
    '--exclude-drafts',
    '--json',
    'tagName,isPrerelease',
    '--jq',
    '.[] | select(.isPrerelease) | .tagName',
  ])
}

function resolveLatestTag(releaseRepository, authenticatedDownload, { gh, curl }) {
  let tag
  if (authenticatedDownload) {
    tag = gh([
      'release',
      'view',
      '--repo',
      releaseRepository,
      '--json',
      'tagName',
      '--jq',
      '.tagName',
    ])
  } else {
    // The public redirect avoids unauthenticated API rate limits on shared runners.
    const latestUrl = curl([
      '--output',
      '/dev/null',
      '--write-out',
      '%{redirect_url}',
      `https://github.com/${releaseRepository}/releases/latest`,
    ])
    tag = latestUrl ? parseLatestReleaseTag(latestUrl, releaseRepository) : ''
  }
  if (!tag) throw new Error(`Could not resolve the latest AI Scan release of ${releaseRepository}`)
  return tag
}

function downloadRelease(
  releaseRepository,
  tag,
  tarball,
  authenticatedDownload,
  { gh, curl, log },
) {
  rmSync(tarball, { force: true })
  if (authenticatedDownload) {
    log(`tools: downloading the release from ${releaseRepository} with authentication using gh`)
    gh([
      'release',
      'download',
      tag,
      '--repo',
      releaseRepository,
      '--pattern',
      ASSET_NAME,
      '--output',
      tarball,
    ])
  } else {
    log(`tools: downloading the release from ${releaseRepository} using curl`)
    curl([
      '--location',
      '--output',
      tarball,
      `https://github.com/${releaseRepository}/releases/download/${tag}/${ASSET_NAME}`,
    ])
  }
}

export function isLocalToolsPath(tools) {
  return tools.startsWith('/') || tools.startsWith('./') || tools.startsWith('../')
}

function parseBunVersion(stamp, tarball) {
  const bunVersion = stamp.trim()
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(bunVersion)) {
    throw new Error(`AI Scan archive ${tarball} contains an invalid Bun version: ${bunVersion}`)
  }
  return bunVersion
}

/**
 * Identifies the bundle format from the archive's entry point. Bun takes
 * priority if both entry points exist. Older bundles contain `argus.js`,
 * which must run on the exact Bun version in `ai-scan-bun-version`.
 */
function validateArchive(tarball, tar) {
  // Map each normalized member name to its name in the archive.
  let entries
  try {
    entries = new Map(
      tar(['-tJf', tarball])
        .split('\n')
        .filter((entry) => entry.trim())
        .map((entry) => [entry.trim().replace(/^\.\//, ''), entry.trim()]),
    )
  } catch (error) {
    throw new Error(`AI Scan archive ${tarball} could not be listed`, { cause: error })
  }
  const hasNodeEntry = entries.has(NODE_ENTRY_POINT)
  const hasBunEntry = entries.has(BUN_ENTRY_POINT)
  // TODO(bun-compat): Remove the Bun path after production bundles use Node.
  if (hasBunEntry) {
    const stampEntry = entries.get(BUN_VERSION_STAMP)
    let stamp
    try {
      if (!stampEntry) throw new Error(`${BUN_VERSION_STAMP} is missing`)
      stamp = tar(['-xJOf', tarball, stampEntry])
    } catch (error) {
      throw new Error(
        `AI Scan archive ${tarball} does not contain a readable ${BUN_VERSION_STAMP} stamp`,
        { cause: error },
      )
    }
    return {
      runtime: 'bun',
      entryPoint: BUN_ENTRY_POINT,
      bunVersion: parseBunVersion(stamp, tarball),
    }
  }
  if (hasNodeEntry) return { runtime: 'node', entryPoint: NODE_ENTRY_POINT, bunVersion: '' }
  throw new Error(
    `AI Scan archive ${tarball} does not contain entry point ${NODE_ENTRY_POINT} or ${BUN_ENTRY_POINT}`,
  )
}

export function resolveTools(
  { tools, releaseRepository, runnerTemp, actionStartedAt, apiUrl, repository },
  dependencies,
) {
  const { isFile, appendOutput, log, tar, gh } = dependencies
  let tarball = tools
  let implementationVersion = ''
  const localTools = isLocalToolsPath(tools) ? isFile(tools) : false

  if (localTools) {
    log(`tools: using local tarball ${tools}`)
  } else {
    log(`tools: ${tools} is not a file`)
    tarball = join(runnerTemp, ASSET_NAME)
    const authenticatedDownload = releaseRepository !== PUBLIC_DISTRIBUTION_REPOSITORY
    let tag = tools
    let releaseDownloaded = false
    if (!tag || tag === 'latest') {
      if (readUseNextRelease(repository, apiUrl, dependencies)) {
        try {
          const pendingTag = resolvePendingTag(releaseRepository, gh)
          if (pendingTag) {
            downloadRelease(
              releaseRepository,
              pendingTag,
              tarball,
              authenticatedDownload,
              dependencies,
            )
            validateArchive(tarball, tar)
            log(`tools: pending release ${pendingTag} is valid`)
            tag = pendingTag
            releaseDownloaded = true
          }
        } catch (error) {
          emitWarningAnnotation(
            `Could not use the pending AI Scan release; falling back to latest (${error.message})`,
            log,
          )
        }
      }
      if (!releaseDownloaded)
        tag = resolveLatestTag(releaseRepository, authenticatedDownload, dependencies)
      log(`tools: selected release ${tag}`)
    }
    implementationVersion = tag
    if (!releaseDownloaded) {
      downloadRelease(releaseRepository, tag, tarball, authenticatedDownload, dependencies)
    }
  }

  const { runtime, entryPoint, bunVersion } = validateArchive(tarball, tar)
  log(`tools: selected archive runs ${entryPoint} on ${runtime}`)
  appendOutput(
    [
      `tarball=${tarball}`,
      `runtime=${runtime}`,
      `entry-point=${entryPoint}`,
      `bun-version=${bunVersion}`,
      `implementation-version=${implementationVersion}`,
      `action-started-at=${actionStartedAt}`,
      '',
    ].join('\n'),
  )
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    resolveTools(
      {
        tools: process.env.TOOLS ?? '',
        releaseRepository: process.env.RELEASE_REPO,
        runnerTemp: process.env.RUNNER_TEMP,
        actionStartedAt: process.env.ACTION_STARTED_AT,
        apiUrl: process.env.GITHUB_API_URL,
        repository: process.env.GITHUB_REPOSITORY,
      },
      {
        gh,
        curl,
        tar,
        isFile: (path) => statSync(path, { throwIfNoEntry: false })?.isFile() ?? false,
        appendOutput: (output) => appendFileSync(process.env.GITHUB_OUTPUT, output),
        log: console.log,
      },
    )
  } catch (error) {
    emitErrorAnnotation(error.message)
    process.exitCode = 1
  }
}
