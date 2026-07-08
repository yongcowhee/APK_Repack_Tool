import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.OutputKeys;
import javax.xml.transform.Transformer;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/**
 * PowerShell(repack_apk_standalone.ps1)을 대체하는 APK 리패키징 도구.
 * ConstrainedLanguage 정책이 적용된 PC에서 PowerShell 스크립트 파일을 로드할 수 없어
 * 동일 로직을 Java로 이식했다.
 *
 * 빌드 방법 (JDK 17 이상 필요):
 *   javac --release 17 RepackApk.java
 *   jar cfe RepackApk.jar RepackApk *.class
 *
 * 빌드된 RepackApk.jar을 tools/repack/RepackApk.jar 에 두면 run.bat이 사용한다.
 * 대상 PC에는 JRE만 있으면 되고(JDK/컴파일러 불필요), 빌드는 개발 시점에 한 번만 하면 된다.
 */
public class RepackApk {

    static final String ANDROID_NS = "http://schemas.android.com/apk/res/android";

    public static void main(String[] args) {
        try {
            run(args);
        } catch (FailException e) {
            System.err.println("[ERROR] " + e.getMessage());
            System.exit(1);
        } catch (Exception e) {
            System.err.println("[ERROR] " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }

    static class FailException extends RuntimeException {
        FailException(String msg) { super(msg); }
    }

    static void fail(String msg) {
        throw new FailException(msg);
    }

    static void run(String[] args) throws Exception {
        Map<String, String> p = parseArgs(args);

        String inputApk = requireArg(p, "input");
        String outputApkArg = requireArg(p, "output");
        String scriptRoot = requireArg(p, "scriptRoot");

        String newPackage = p.getOrDefault("package", "");
        String versionCode = p.getOrDefault("versionCode", "");
        String versionName = p.getOrDefault("versionName", "");
        String minSdk = p.getOrDefault("minSdk", "");
        String targetSdk = p.getOrDefault("targetSdk", "");
        String maxSdk = p.getOrDefault("maxSdk", "");
        boolean fullSmali = p.containsKey("fullSmali");
        boolean keepTemp = p.containsKey("keepTemp");

        // ---- 유효성 검사 (기존 PowerShell 로직과 동일) ----
        if (!isBlankOrNull(newPackage)) {
            if (!newPackage.matches("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")) {
                fail("Invalid package name: " + newPackage);
            }
        }
        validateNumericOrNull(versionCode, "VersionCode");
        validateNumericOrNull(minSdk, "MinSdk");
        validateNumericOrNull(targetSdk, "TargetSdk");
        validateNumericOrNull(maxSdk, "MaxSdk");

        if (isBlank(inputApk)) fail("Input APK path is empty.");
        File inputFile = new File(inputApk).getCanonicalFile();
        if (!inputFile.isFile()) fail("Input APK not found: " + inputFile);

        if (isBlank(outputApkArg)) fail("Output APK path is empty.");
        File outputFile = resolveOutputPath(outputApkArg, inputFile);

        File toolsDir = new File(new File(scriptRoot).getCanonicalFile(), "tools");
        File javaExe = new File(toolsDir, "java" + File.separator + "bin" + File.separator + "java.exe");
        String javaCmd = javaExe.isFile() ? javaExe.getAbsolutePath() : "java";

        File apktoolJar = requireFile(new File(toolsDir, "apktool" + File.separator + "apktool.jar"));
        File apksignerJar = requireFile(new File(toolsDir, "build-tools" + File.separator + "lib" + File.separator + "apksigner.jar"));
        File zipalign = requireFile(new File(toolsDir, "build-tools" + File.separator + "zipalign.exe"));

        String[] ks = resolveKeystore(toolsDir);
        String keystorePath = ks[0];
        String keyAlias = ks[1];
        String storePass = ks[2];
        String keyPass = ks[3];
        requireFile(new File(keystorePath));

        File workRoot = new File(System.getProperty("java.io.tmpdir"),
                "repack_apk_" + UUID.randomUUID().toString().replace("-", ""));
        File decodedDir = new File(workRoot, "decoded");
        File unsignedApk = new File(workRoot, "unsigned.apk");
        File alignedApk = new File(workRoot, "aligned.apk");

        try {
            if (workRoot.exists()) deleteRecursive(workRoot);
            workRoot.mkdirs();

            runChecked(javaCmd, "-Xmx3g", "-jar", apktoolJar.getAbsolutePath(),
                    "d", "-f", inputFile.getAbsolutePath(), "-o", decodedDir.getAbsolutePath());

            File manifestFile = new File(decodedDir, "AndroidManifest.xml");
            File ymlFile = new File(decodedDir, "apktool.yml");

            String oldPackage = readOldPackage(manifestFile);
            System.out.println("Old package: " + oldPackage);

            String effectiveNewPackage;
            if (isBlankOrNull(newPackage)) {
                effectiveNewPackage = oldPackage;
                System.out.println("New package: (Not specified. Keeping original package)");
            } else {
                effectiveNewPackage = newPackage;
                System.out.println("New package: " + effectiveNewPackage);
            }

            updateManifest(manifestFile, oldPackage, effectiveNewPackage,
                    versionCode, versionName, minSdk, targetSdk, maxSdk);
            updateApktoolYml(ymlFile, effectiveNewPackage,
                    versionCode, versionName, minSdk, targetSdk, maxSdk);

            if (fullSmali && !oldPackage.equals(effectiveNewPackage)) {
                int moves = moveSmaliPackageDirs(decodedDir, oldPackage, effectiveNewPackage);
                int changed = replaceInTree(decodedDir, oldPackage, effectiveNewPackage);
                System.out.println("Moved smali dirs: " + moves + ", updated files: " + changed);
            } else if (fullSmali) {
                System.out.println("FullSmali skipped: Package name has not changed.");
            } else {
                System.out.println("Manifest-only mode (add -FullSmali for smali tree rename)");
            }

            if (unsignedApk.exists()) unsignedApk.delete();
            runChecked(javaCmd, "-Xmx3g", "-jar", apktoolJar.getAbsolutePath(),
                    "b", decodedDir.getAbsolutePath(), "-o", unsignedApk.getAbsolutePath());

            if (alignedApk.exists()) alignedApk.delete();
            runChecked(zipalign.getAbsolutePath(), "-f", "4",
                    unsignedApk.getAbsolutePath(), alignedApk.getAbsolutePath());

            File outParent = outputFile.getParentFile();
            if (outParent != null) outParent.mkdirs();
            if (outputFile.exists()) outputFile.delete();
            Files.copy(alignedApk.toPath(), outputFile.toPath(), StandardCopyOption.REPLACE_EXISTING);

            runCheckedMasked(new String[]{
                    javaCmd, "-Xmx3g", "-jar", apksignerJar.getAbsolutePath(), "sign",
                    "--v2-signing-enabled", "true",
                    "--v3-signing-enabled", "true",
                    "--ks", keystorePath,
                    "--ks-pass", "pass:" + storePass,
                    "--key-pass", "pass:" + keyPass,
                    "--ks-key-alias", keyAlias,
                    outputFile.getAbsolutePath()
            }, new String[]{"pass:" + storePass, "pass:" + keyPass});

            runChecked(javaCmd, "-Xmx3g", "-jar", apksignerJar.getAbsolutePath(),
                    "verify", "--verbose", outputFile.getAbsolutePath());

            System.out.println("Done: " + outputFile.getAbsolutePath());
            if (keepTemp) {
                System.out.println("Temp kept: " + workRoot.getAbsolutePath());
            }
        } finally {
            if (!keepTemp && workRoot.exists()) {
                deleteRecursive(workRoot);
            }
        }
    }

    // ---------------------------------------------------------------------
    // 인자 파싱
    // ---------------------------------------------------------------------

    static Map<String, String> parseArgs(String[] args) {
        Map<String, String> map = new HashMap<>();
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if (!a.startsWith("--")) continue;
            String key = a.substring(2);
            if (key.equals("fullSmali") || key.equals("keepTemp")) {
                map.put(key, "true");
                continue;
            }
            String value = "";
            if (i + 1 < args.length && !args[i + 1].startsWith("--")) {
                value = args[i + 1];
                i++;
            }
            map.put(key, value);
        }
        return map;
    }

    static String requireArg(Map<String, String> p, String key) {
        String v = p.get(key);
        if (v == null) fail("Missing required argument: --" + key);
        return v;
    }

    // ---------------------------------------------------------------------
    // 유효성 검사
    // ---------------------------------------------------------------------

    static boolean isBlank(String s) {
        return s == null || s.trim().isEmpty();
    }

    static boolean isBlankOrNull(String s) {
        return isBlank(s) || "null".equalsIgnoreCase(s.trim());
    }

    static void validateNumericOrNull(String value, String fieldName) {
        if (isBlank(value)) return;
        if ("null".equalsIgnoreCase(value.trim())) return;
        if (!value.trim().matches("^[0-9]+$")) {
            fail(fieldName + " must be a valid number or 'null'! (Input: '" + value + "')");
        }
    }

    static File requireFile(File f) {
        if (!f.isFile()) {
            fail("Required bundled file not found: " + f.getAbsolutePath());
        }
        return f;
    }

    // ---------------------------------------------------------------------
    // 출력 경로 결정 (파일명만 입력 시 input apk와 동일 디렉토리, 확장자 강제 .apk)
    // ---------------------------------------------------------------------

    static File resolveOutputPath(String outputApkArg, File inputFile) throws IOException {
        File asGiven = new File(outputApkArg);
        File resolved;
        String parent = asGiven.getParent();
        if (parent == null) {
            // 디렉토리 구성요소가 없음 -> input apk와 동일 디렉토리를 기본 경로로 사용
            resolved = new File(inputFile.getParentFile(), outputApkArg);
        } else {
            resolved = asGiven.getCanonicalFile();
        }

        String name = resolved.getName();
        Matcher m = Pattern.compile("\\.[^.\\\\/]+$").matcher(name);
        if (m.find()) {
            if (!m.group().equalsIgnoreCase(".apk")) {
                name = m.replaceAll(".apk");
            }
        } else {
            name = name + ".apk";
        }
        return new File(resolved.getParentFile(), name);
    }

    // ---------------------------------------------------------------------
    // 서명 키 결정: tools/keystore/keystore.config 우선, 없으면 debug.keystore 폴백
    // ---------------------------------------------------------------------

    static String[] resolveKeystore(File toolsDir) throws IOException {
        File configFile = new File(toolsDir, "keystore" + File.separator + "keystore.config");
        if (configFile.isFile()) {
            Map<String, String> cfg = new HashMap<>();
            for (String line : Files.readAllLines(configFile.toPath(), StandardCharsets.UTF_8)) {
                String t = line.trim();
                if (t.isEmpty() || t.startsWith("#")) continue;
                int idx = t.indexOf('=');
                if (idx > 0) {
                    cfg.put(t.substring(0, idx).trim(), t.substring(idx + 1).trim());
                }
            }
            String path = cfg.get("KeystorePath");
            String alias = cfg.get("KeyAlias");
            String storePass = cfg.get("StorePassword");
            String keyPass = cfg.get("KeyPassword");

            boolean complete = !isBlank(path) && !isBlank(alias) && !isBlank(storePass) && !isBlank(keyPass);
            if (complete) {
                File ksFile = new File(path);
                if (!ksFile.isAbsolute()) {
                    ksFile = new File(configFile.getParentFile(), path);
                }
                if (!ksFile.isFile()) {
                    fail("keystore.config에 지정된 키 파일을 찾을 수 없습니다: " + ksFile.getAbsolutePath());
                }
                System.out.println("-> Signing: keystore.config에 등록된 서명 키를 사용합니다. (alias=" + alias + ")");
                return new String[]{ksFile.getAbsolutePath(), alias, storePass, keyPass};
            } else {
                System.out.println("-> [WARNING] keystore.config가 존재하지만 필수 값이 비어 있어 기본 debug 키로 폴백합니다.");
            }
        } else {
            System.out.println("-> [WARNING] keystore.config가 없어 기본 debug 키로 서명합니다. 스토어 업로드용 APK에는 사용할 수 없습니다.");
        }

        File debugKs = new File(toolsDir, "keystore" + File.separator + "debug.keystore");
        return new String[]{debugKs.getAbsolutePath(), "androiddebugkey", "android", "android"};
    }

    // ---------------------------------------------------------------------
    // AndroidManifest.xml 처리
    // ---------------------------------------------------------------------

    static String readOldPackage(File manifestFile) throws Exception {
        Document doc = parseXml(manifestFile);
        Element manifest = doc.getDocumentElement();
        if (!manifest.hasAttribute("package")) {
            fail("package attribute not found: " + manifestFile);
        }
        return manifest.getAttribute("package");
    }

    static void updateManifest(File manifestFile, String oldPackage, String newPackage,
                                String versionCode, String versionName,
                                String minSdk, String targetSdk, String maxSdk) throws Exception {
        Document doc = parseXml(manifestFile);
        Element manifest = doc.getDocumentElement();
        boolean modified = false;

        // 패키지명 변경
        if (!isBlankOrNull(newPackage) && !newPackage.equals(oldPackage)) {
            if (manifest.getAttribute("package").equals(oldPackage)) {
                manifest.setAttribute("package", newPackage);
                modified = true;
                System.out.println("-> Manifest: Updated package name to " + newPackage);
            } else {
                fail("expected package " + oldPackage + " in " + manifestFile);
            }
        }

        boolean hasVCode = !isBlankOrNull(versionCode);
        boolean hasVName = !isBlankOrNull(versionName);
        boolean hasMin = !isBlankOrNull(minSdk);
        boolean hasTarget = !isBlank(targetSdk);
        boolean hasMax = !isBlank(maxSdk);

        if (hasVCode) {
            manifest.setAttributeNS(ANDROID_NS, "android:versionCode", versionCode);
            System.out.println("-> Manifest: Updated versionCode to " + versionCode);
            modified = true;
        }
        if (hasVName) {
            manifest.setAttributeNS(ANDROID_NS, "android:versionName", versionName);
            System.out.println("-> Manifest: Updated versionName to " + versionName);
            modified = true;
        }

        Element usesSdk = firstChildElement(manifest, "uses-sdk");
        boolean hasNewSdkValue = hasMin || hasTarget || hasMax;
        if (usesSdk == null && hasNewSdkValue) {
            usesSdk = doc.createElement("uses-sdk");
            manifest.appendChild(usesSdk);
            System.out.println("-> Manifest: Created missing <uses-sdk> element securely.");
        }

        if (usesSdk != null) {
            if (hasMin) {
                usesSdk.setAttributeNS(ANDROID_NS, "android:minSdkVersion", minSdk);
                System.out.println("-> Manifest: Updated minSdkVersion to " + minSdk);
                modified = true;
            }
            if (hasTarget) {
                if ("null".equalsIgnoreCase(targetSdk.trim())) {
                    if (usesSdk.hasAttributeNS(ANDROID_NS, "targetSdkVersion")) {
                        usesSdk.removeAttributeNS(ANDROID_NS, "targetSdkVersion");
                        System.out.println("-> Manifest: Removed targetSdkVersion attribute");
                        modified = true;
                    }
                } else {
                    usesSdk.setAttributeNS(ANDROID_NS, "android:targetSdkVersion", targetSdk);
                    System.out.println("-> Manifest: Updated targetSdkVersion to " + targetSdk);
                    modified = true;
                }
            }
            if (hasMax) {
                if ("null".equalsIgnoreCase(maxSdk.trim())) {
                    if (usesSdk.hasAttributeNS(ANDROID_NS, "maxSdkVersion")) {
                        usesSdk.removeAttributeNS(ANDROID_NS, "maxSdkVersion");
                        System.out.println("-> Manifest: Removed maxSdkVersion attribute");
                        modified = true;
                    }
                } else {
                    usesSdk.setAttributeNS(ANDROID_NS, "android:maxSdkVersion", maxSdk);
                    System.out.println("-> Manifest: Updated maxSdkVersion to " + maxSdk);
                    modified = true;
                }
            }
        }

        if (modified) {
            saveXml(doc, manifestFile);
        }
    }

    static Element firstChildElement(Element parent, String tagName) {
        NodeList children = parent.getElementsByTagName(tagName);
        if (children.getLength() == 0) return null;
        return (Element) children.item(0);
    }

    static Document parseXml(File file) throws Exception {
        DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
        dbf.setNamespaceAware(true);
        DocumentBuilder db = dbf.newDocumentBuilder();
        try (InputStream in = Files.newInputStream(file.toPath())) {
            return db.parse(in);
        }
    }

    static void saveXml(Document doc, File file) throws Exception {
        TransformerFactory tf = TransformerFactory.newInstance();
        Transformer t = tf.newTransformer();
        t.setOutputProperty(OutputKeys.ENCODING, "UTF-8");
        t.setOutputProperty(OutputKeys.OMIT_XML_DECLARATION, "no");
        try (var out = Files.newOutputStream(file.toPath())) {
            t.transform(new DOMSource(doc), new StreamResult(out));
        }
    }

    // ---------------------------------------------------------------------
    // apktool.yml 처리 (텍스트 기반 치환, 기존 PowerShell 정규식 로직과 동일)
    // ---------------------------------------------------------------------

    static void updateApktoolYml(File ymlFile, String newPackage,
                                  String versionCode, String versionName,
                                  String minSdk, String targetSdk, String maxSdk) throws IOException {
        String text = new String(Files.readAllBytes(ymlFile.toPath()), StandardCharsets.UTF_8);

        if (!isBlankOrNull(newPackage)) {
            if (Pattern.compile("(?m)^renameManifestPackage:").matcher(text).find()) {
                text = Pattern.compile("(?m)^renameManifestPackage:.*$")
                        .matcher(text).replaceAll(Matcher.quoteReplacement("renameManifestPackage: " + newPackage));
            } else {
                text = rtrim(text) + "\nrenameManifestPackage: " + newPackage + "\n";
            }
            text = Pattern.compile("(?m)^(  packageName:)\\s*$")
                    .matcher(text).replaceAll(Matcher.quoteReplacement("$1 " + newPackage));
            System.out.println("-> apktool.yml: Updated package name to " + newPackage);
        }

        if (!isBlankOrNull(versionCode)) {
            text = replaceYmlField(text, "  versionCode:", versionCode, "versionCode");
        }
        if (!isBlankOrNull(versionName)) {
            text = replaceYmlField(text, "  versionName:", versionName, "versionName");
        }
        if (!isBlankOrNull(minSdk)) {
            text = replaceYmlField(text, "    minSdkVersion:", minSdk, "minSdkVersion");
        }
        if (!isBlank(targetSdk)) {
            if ("null".equalsIgnoreCase(targetSdk.trim())) {
                text = removeYmlSdkField(text, "targetSdkVersion");
            } else {
                text = replaceOrAddSdkInfoField(text, "targetSdkVersion", targetSdk);
            }
        }
        if (!isBlank(maxSdk)) {
            if ("null".equalsIgnoreCase(maxSdk.trim())) {
                text = removeYmlSdkField(text, "maxSdkVersion");
            } else {
                text = replaceOrAddSdkInfoField(text, "maxSdkVersion", maxSdk);
            }
        }

        Files.write(ymlFile.toPath(), text.getBytes(StandardCharsets.UTF_8));
    }

    static String replaceYmlField(String text, String prefix, String value, String label) {
        Pattern pat = Pattern.compile("(?m)^" + Pattern.quote(prefix) + "\\s*.*$");
        Matcher m = pat.matcher(text);
        if (m.find()) {
            String replaced = m.replaceAll(Matcher.quoteReplacement(prefix + " " + value));
            System.out.println("-> apktool.yml: Updated " + label + " to " + value);
            return replaced;
        }
        return text;
    }

    static String replaceOrAddSdkInfoField(String text, String fieldName, String value) {
        Pattern fieldPat = Pattern.compile("(?m)^    " + Pattern.quote(fieldName) + ":\\s*.*$");
        Matcher m = fieldPat.matcher(text);
        if (m.find()) {
            String replaced = m.replaceAll(Matcher.quoteReplacement("    " + fieldName + ": " + value));
            System.out.println("-> apktool.yml: Updated " + fieldName + " to " + value);
            return replaced;
        }
        Pattern sdkInfoPat = Pattern.compile("(?m)^  sdkInfo:\\s*$");
        Matcher m2 = sdkInfoPat.matcher(text);
        if (m2.find()) {
            String replaced = m2.replaceAll(Matcher.quoteReplacement("  sdkInfo:\n    " + fieldName + ": " + value));
            System.out.println("-> apktool.yml: Added and Updated " + fieldName + " to " + value);
            return replaced;
        }
        return text;
    }

    static String removeYmlSdkField(String text, String fieldName) {
        // apktool은 매니페스트에 해당 속성이 없으면 apktool.yml에 그 키 자체를 만들지 않는다.
        // "null" 텍스트로 값만 지우는 방식은 aapt2가 프레임워크 기본값으로 채워넣는 부작용이 있어,
        // 줄 자체를 완전히 제거해 apktool의 원래 "속성 없음" 상태와 동일하게 맞춘다.
        Pattern pat = Pattern.compile("(?m)^    " + Pattern.quote(fieldName) + ":\\s*.*$\\r?\\n?");
        Matcher m = pat.matcher(text);
        if (m.find()) {
            String replaced = m.replaceAll("");
            System.out.println("-> apktool.yml: Removed " + fieldName + " field");
            return replaced;
        }
        return text;
    }

    static String rtrim(String s) {
        int end = s.length();
        while (end > 0 && Character.isWhitespace(s.charAt(end - 1))) end--;
        return s.substring(0, end);
    }

    // ---------------------------------------------------------------------
    // FullSmali: 패키지 디렉토리 이동 + 파일 내용 치환
    // ---------------------------------------------------------------------

    static int moveSmaliPackageDirs(File decodedDir, String oldPackage, String newPackage) throws IOException {
        String oldRel = oldPackage.replace(".", File.separator);
        String newRel = newPackage.replace(".", File.separator);
        int moves = 0;

        File[] children = decodedDir.listFiles();
        if (children == null) return 0;
        for (File dir : children) {
            if (!dir.isDirectory() || !dir.getName().startsWith("smali")) continue;
            File oldDir = new File(dir, oldRel);
            File newDir = new File(dir, newRel);
            if (oldDir.isDirectory()) {
                File newParent = newDir.getParentFile();
                if (newParent != null) newParent.mkdirs();
                if (newDir.exists()) deleteRecursive(newDir);
                Files.move(oldDir.toPath(), newDir.toPath());
                moves++;
            }
        }
        return moves;
    }

    static int replaceInTree(File root, String oldPackage, String newPackage) throws IOException {
        String oldSmali = "L" + oldPackage.replace(".", "/");
        String newSmali = "L" + newPackage.replace(".", "/");
        java.util.List<String> allowedExt = java.util.Arrays.asList(".smali", ".xml", ".txt", ".json", ".properties");
        int[] changed = {0};

        try (Stream<Path> walk = Files.walk(root.toPath())) {
            walk.filter(Files::isRegularFile).forEach(path -> {
                File f = path.toFile();
                String ext = "";
                int dot = f.getName().lastIndexOf('.');
                if (dot >= 0) ext = f.getName().substring(dot);
                if (!allowedExt.contains(ext) && !f.getName().equals("AndroidManifest.xml")) {
                    return;
                }
                try {
                    String text = new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
                    String updated = text.replace(oldSmali, newSmali).replace(oldPackage, newPackage);
                    if (!updated.equals(text)) {
                        Files.write(path, updated.getBytes(StandardCharsets.UTF_8));
                        changed[0]++;
                    }
                } catch (IOException e) {
                    throw new RuntimeException(e);
                }
            });
        }
        return changed[0];
    }

    // ---------------------------------------------------------------------
    // 외부 프로세스 실행
    // ---------------------------------------------------------------------

    static void runChecked(String... command) throws IOException, InterruptedException {
        runCheckedMasked(command, new String[0]);
    }

    static void runCheckedMasked(String[] command, String[] maskValues) throws IOException, InterruptedException {
        StringBuilder display = new StringBuilder("$ ");
        for (String c : command) {
            String shown = c;
            for (String m : maskValues) {
                if (m != null && !m.isEmpty() && c.equals(m)) {
                    shown = "****";
                    break;
                }
            }
            display.append(shown).append(" ");
        }
        System.out.println(display.toString().trim());

        ProcessBuilder pb = new ProcessBuilder(command);
        pb.inheritIO();
        Process proc = pb.start();
        int exitCode = proc.waitFor();
        if (exitCode != 0) {
            fail("Command failed with exit code " + exitCode + ": " + command[0]);
        }
    }

    static void deleteRecursive(File f) {
        if (f == null || !f.exists()) return;
        File[] children = f.listFiles();
        if (children != null) {
            for (File c : children) deleteRecursive(c);
        }
        f.delete();
    }
}
