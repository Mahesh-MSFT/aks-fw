FROM maven:3.5-jdk-8 as BUILD
  
COPY SqlInjection/src /usr/src/sji/src
COPY SqlInjection/pom.xml /usr/src/sji
RUN mvn -f /usr/src/sji/pom.xml clean package

FROM tomcat:jdk8-openjdk
WORKDIR /

COPY --from=build /usr/src/sji/target/jsi.war /usr/local/tomcat/webapps/jsi.war

EXPOSE 80

CMD ["catalina.sh", "run"]