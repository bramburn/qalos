import React from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';

import styles from './index.module.css';

function HomepageHeader() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <header className={clsx('hero', 'hero--primary', styles.heroBanner)}>
      <div className="container">
        <Heading as="h1" className="hero__title">
          {siteConfig.title}
        </Heading>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--secondary button--lg"
            to="/docs/intro">
            Get started →
          </Link>
          <Link
            className={clsx('button', 'button--outline', 'button--secondary', 'button--lg', styles.githubButton)}
            href="https://github.com/bramburn/qalos">
            View on GitHub
          </Link>
        </div>
      </div>
    </header>
  );
}

function FeatureRow({ title, description, linkTo }) {
  return (
    <div className={clsx('col', 'col--4', styles.feature)}>
      <div className="padding-horiz--md padding-vert--md">
        <Heading as="h3">{title}</Heading>
        <p>{description}</p>
        {linkTo && <Link to={linkTo}>Read more →</Link>}
      </div>
    </div>
  );
}

function HomepageFeatures() {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          <FeatureRow
            title="Local-first"
            description="Build on your Linux box in 1-4 hours. $0 marginal cost, no rate limits, no SSH round-trip. The primary path."
            linkTo="/docs/getting-started/local-build"
          />
          <FeatureRow
            title="Two cloud fallbacks"
            description="DigitalOcean for clean-room CI; Aliyun for China region and cheaper spot pricing. Both reuse the same on-host build script."
            linkTo="/docs/getting-started/do-build"
          />
          <FeatureRow
            title="Four safety nets"
            description="Every build script guarantees the cloud instance is destroyed, even on parent process death, hard kill, network loss, or uncaught exception."
            linkTo="/docs/architecture/safety-nets"
          />
        </div>
      </div>
    </section>
  );
}

export default function Home() {
  return (
    <Layout
      title="QA Lab Operating System"
      description="qalos is an AOSP fork for QA Lab use. Opinionated build system, clean CI, four-safety-net scripts.">
      <HomepageHeader />
      <main>
        <HomepageFeatures />
      </main>
    </Layout>
  );
}
