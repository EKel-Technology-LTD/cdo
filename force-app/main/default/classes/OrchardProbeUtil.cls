public with sharing class OrchardProbeUtil {
    public static String normalizeNote(String s) {
        if (String.isBlank(s)) {
            return null;
        }
        String normalized = s.trim();
        if (normalized.length() > 50) {
            return normalized.substring(0, 50);
        }
        return normalized;
    }
}
