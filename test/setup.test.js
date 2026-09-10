import { test, expect } from "bun:test";
import { normalizeUrl, normalizeTotp, urlError, firstProblem } from "../src/setup.js";

test("a bare hostname is assumed to be https", () => {
    expect(normalizeUrl("kuma.example.com")).toBe("https://kuma.example.com");
});

test("an explicit scheme is left alone, including http for a box on the LAN", () => {
    expect(normalizeUrl("http://192.168.1.10:3001")).toBe("http://192.168.1.10:3001");
});

test("surrounding whitespace and trailing slashes are dropped", () => {
    expect(normalizeUrl("  https://kuma.example.com/  ")).toBe("https://kuma.example.com");
    expect(normalizeUrl("https://kuma.example.com///")).toBe("https://kuma.example.com");
});

test("a URL copied out of the browser's address bar loses the dashboard path", () => {
    expect(normalizeUrl("https://kuma.example.com/dashboard")).toBe("https://kuma.example.com");
    expect(normalizeUrl("https://kuma.example.com/dashboard/12")).toBe("https://kuma.example.com");
});

test("a subpath that is not the dashboard survives", () => {
    expect(normalizeUrl("https://example.com/kuma")).toBe("https://example.com/kuma");
});

test("normalizing nothing yields nothing, rather than a bare scheme", () => {
    expect(normalizeUrl("")).toBe("");
    expect(normalizeUrl("   ")).toBe("");
    expect(normalizeUrl(null)).toBe("");
});

test("a URL is only accepted in the shape the login helper insists on", () => {
    expect(urlError("kuma.example.com")).toBe("");
    expect(urlError("https://kuma.example.com")).toBe("");
    expect(urlError("")).not.toBe("");
    expect(urlError("ftp://kuma.example.com")).not.toBe("");
    expect(urlError("https://")).not.toBe("");
    expect(urlError("has spaces.example.com")).not.toBe("");
});

test("a two-factor code keeps only its digits, so a grouped code pastes cleanly", () => {
    expect(normalizeTotp(" 123 456 ")).toBe("123456");
    expect(normalizeTotp("")).toBe("");
    expect(normalizeTotp(null)).toBe("");
});

const filled = {
    baseUrl: "https://kuma.example.com",
    username: "you",
    password: "hunter2",
    totp: "",
    totpRequired: false,
};

test("a complete form has no problem to report", () => {
    expect(firstProblem(filled)).toBe(null);
});

test("problems are reported in the order the fields are read", () => {
    const empty = { baseUrl: "", username: "", password: "", totp: "", totpRequired: false };
    expect(firstProblem(empty).field).toBe("baseUrl");
    expect(firstProblem({ ...empty, baseUrl: "kuma.example.com" }).field).toBe("username");
    expect(firstProblem({ ...filled, password: "" }).field).toBe("password");
});

test("every problem names the field and says what to do about it", () => {
    const problem = firstProblem({ ...filled, username: "  " });
    expect(problem.field).toBe("username");
    expect(problem.message.length).toBeGreaterThan(0);
});

test("a two-factor code is demanded only once the server has asked for one", () => {
    expect(firstProblem({ ...filled, totpRequired: true }).field).toBe("totp");
    expect(firstProblem({ ...filled, totp: "123456", totpRequired: true })).toBe(null);
    expect(firstProblem({ ...filled, totp: "12345", totpRequired: true }).field).toBe("totp");
});

test("a volunteered two-factor code is still checked before it is spent", () => {
    expect(firstProblem({ ...filled, totp: "12345" }).field).toBe("totp");
    expect(firstProblem({ ...filled, totp: "123456" })).toBe(null);
});

test("a password made of spaces is a password, and is never trimmed away", () => {
    expect(firstProblem({ ...filled, password: "  " })).toBe(null);
});
