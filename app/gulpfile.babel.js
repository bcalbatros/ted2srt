import gulp from 'gulp';
import path from 'path';
import preprocess from 'gulp-preprocess';
import sass from 'gulp-sass';
import {exec} from 'shelljs';
import webserver from 'gulp-webserver';
import yargs from 'yargs';

const DEST = 'www';
const isProd = (process.env.NODE_ENV === 'production') ? true : false;
const argv = yargs.argv;

gulp.task('fonts', () => {
  return gulp.src('bower_components/ionic/release/fonts/*')
    .pipe(gulp.dest(path.join(DEST, 'fonts')));
});

gulp.task('styles', () => {
  gulp.src('./scss/ionic.app.scss')
    .pipe(sass({
      errLogToConsole: true
    }))
    .pipe(gulp.dest('./www/css/'));

  return gulp.src('src/css/**/*.css', {base: 'src'})
    .pipe(gulp.dest(DEST));
});

gulp.task('scripts', () => {
  gulp.src([
    'bower_components/ionic/release/js/ionic.bundle.js',
    'bower_components/angular-resource/angular-resource.js'
    ])
    .pipe(gulp.dest('./www/js'));

  return gulp.src('src/js/**/*.js', {base: 'src'})
    .pipe(preprocess())
    .pipe(gulp.dest(DEST));
});

gulp.task('html', () => {
  return gulp.src('src/**/*.html')
    .pipe(preprocess())
    .pipe(gulp.dest(DEST));
});

gulp.task('default', ['fonts', 'styles', 'scripts', 'html']);

gulp.task('serve', ['default'], () => {
  gulp.src(DEST)
    .pipe(webserver({
      port: 9000,
      livereload: true,
      proxies: [
        {
          source: '/api',
          target: 'http://localhost:3001'
        }
      ]
    }));

  gulp.watch(['src/css/**/*.css'], ['styles']);
  gulp.watch(['src/js/**/*.js'], ['scripts']);
  gulp.watch(['src/**/*.html'], ['html']);
});

gulp.task('build', ['default'], () => {
  if (!isProd) {
    throw new Error('Requires NODE_ENV set to production, run `NODE_ENV=production gulp build`');
  }
});

gulp.task('run', ['default'], () => {
  // NODE_ENV=production gulp run --platform android
  // gulp run -r
  let platform = argv.platform || argv.p || 'android';
  let reload = argv.r ? '--livereload' : '';
  exec(`ionic run ${platform} ${reload}`);
});
