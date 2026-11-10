import native from 'libdeckcraft.so';
import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { publishSystemTheme, systemThemeFromColorMode } from '../SystemTheme';

class SystemThemeInput {
  kind: string = 'system_theme';
  text: string = '';
  constructor(text: string) { this.text = text; }
}

class LocaleCommandParams {
  language: string = '';
  locale: string = '';
  constructor(language: string, locale: string) {
    this.language = language;
    this.locale = locale;
  }
}

class LocaleCommand {
  id: string = 'host.setLocale';
  params: LocaleCommandParams;
  constructor(language: string, locale: string) {
    this.params = new LocaleCommandParams(language, locale);
  }
}

export default class EntryAbility extends UIAbility {
  // 启动时 native.init 已把语言带进 Rust；这里只在系统语言真的变化时追加通知。
  private lastLocale: string = '';
  private syncSystemTheme(colorMode: number | undefined): void {
    const theme = systemThemeFromColorMode(colorMode);
    publishSystemTheme(theme);
    // Push live changes into the native worker; init also carries the first value.
    try {
      native.input(JSON.stringify(new SystemThemeInput(theme)));
    } catch (error) {
      console.info('System theme input unavailable before native init');
    }
  }

  private currentLocaleTag(): string {
    let locale: string = '';
    try {
      locale = i18n.System.getSystemLocale();
    } catch (error) {
      console.info(`System locale unavailable: ${(error as Error).message}`);
    }
    const language = i18n.System.getSystemLanguage();
    return locale.length > 0 ? locale : language;
  }

  /** 跟随系统语言：设置里切换语言后，Rust 侧的翻译开关与界面即时更新。 */
  private syncSystemLocale(): void {
    const tag = this.currentLocaleTag();
    if (tag === this.lastLocale) {
      return;
    }
    this.lastLocale = tag;
    try {
      const language = i18n.System.getSystemLanguage();
      const locale = tag === language ? '' : tag;
      native.command(JSON.stringify(new LocaleCommand(language, locale)));
    } catch (error) {
      console.info(`Locale command unavailable: ${(error as Error).message}`);
    }
  }

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.syncSystemTheme(this.context.config?.colorMode);
    // 冷启动时只记录当前语言，首次语言由 native.init 的 config 带下去。
    this.lastLocale = this.currentLocaleTag();
    // 冷启动的文件 URI 只在 onCreate 出现；热启动才走 onNewWant（GridCraft 实测）。
    if (want?.uri) {
      AppStorage.setOrCreate('deckcraftOpenWant', want.uri);
    }
    console.info('DeckCraft native ability created');
  }

  onNewWant(want: Want): void {
    // A file opened from the system shares its URI through startAbility; the page drains it on load.
    if (want?.uri) {
      AppStorage.setOrCreate('deckcraftOpenWant', want.uri);
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncSystemTheme(newConfig.colorMode);
    this.syncSystemLocale();
  }

  onForeground(): void {
    native.active(true);
    // 兜底：某些设备不派发 onConfigurationUpdate，回到前台时再比对一次。
    this.syncSystemLocale();
  }

  onBackground(): void {
    native.active(false);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    if (AppStorage.get<string>('deckcraftSystemTheme') === undefined) {
      this.syncSystemTheme(this.context.config?.colorMode);
    }
    // 系统标题栏的关闭按钮：交给引擎做未保存确认。
    // SDK 声明为 on('windowWillClose', Callback<void, Promise<boolean>>)（@since 15），
    // 回调必须返回 Promise<boolean>；返回 true 拦截，false 放行。
    // 用户点 Save / Don't Save 后 Rust 会 notify('close') → terminateSelf。
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.on('windowWillClose', async (): Promise<boolean> => {
        try {
          native.close();
          return true;
        } catch (error) {
          // native 未就绪时不能把窗口锁死，放行系统关闭作为兜底。
          console.warn(`DeckCraft native close unavailable: ${(error as Error).message}`);
          return false;
        }
      });
    } catch (error) {
      console.warn(`DeckCraft windowWillClose unavailable: ${(error as Error).message}`);
    }
    windowStage.loadContent('pages/Index', (error: BusinessError) => {
      if (error.code) {
        console.error(`DeckCraft page failed: ${error.code} ${error.message}`);
      }
    });
  }
}
